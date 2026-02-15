defmodule RadioBeamWeb.ContentRepoController do
  @moduledoc """
  Endpoints for retrieving and uploading media and files
  """
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [json_error: 4, halting_json_error: 4]

  alias RadioBeam.ContentRepo.MatrixContentURI
  alias RadioBeam.ContentRepo
  alias RadioBeamWeb.Schemas.ContentRepo, as: ContentRepoSchema

  require Logger

  plug RadioBeamWeb.Plugs.EnforceSchema, [mod: ContentRepoSchema] when action in [:thumbnail, :download]
  plug :parse_mxc when action in [:thumbnail, :download]

  plug :parse_mime when action == :upload

  @must_reserve_error_msg "You must reserve a content URI first"
  @unknown_error_msg "An unknown error occurred while uploading your file - please try again"
  @overwrite_error_msg "A file already exists under this URI"

  def config(conn, _params) do
    json(conn, %{"m.upload.size" => ContentRepo.max_upload_size_bytes()})
  end

  def download(conn, params) do
    request = conn.assigns.request
    mxc = conn.assigns.mxc

    case ContentRepo.download_info_for(mxc, timeout: request["timeout_ms"]) do
      {:ok, file_type, filename, path} ->
        content_type = MIME.type(file_type)
        disposition = if content_type in content_types_to_inline(), do: :inline, else: :attachment

        send_download(conn, {:file, path},
          filename: Map.get(params, "filename", filename),
          content_type: content_type,
          disposition: disposition
        )

      error ->
        handle_error(conn, error)
    end
  end

  def thumbnail(conn, _params) do
    request = conn.assigns.request
    mxc = conn.assigns.mxc
    spec = {request["width"], request["height"], request["method"]}

    case ContentRepo.thumbnail_info_for(mxc, spec, timeout: request["timeout_ms"]) do
      {:ok, file_type, _upload_filename, thumbnail_path} ->
        send_download(conn, {:file, thumbnail_path},
          filename: "thumbnail.#{file_type}",
          content_type: MIME.type(file_type),
          disposition: :inline
        )

      {:error, :invalid_spec} ->
        json_error(conn, 400, :bad_json, "The given thumbnail width, height, or method is not supported")

      {:error, {:cannot_thumbnail, type}} ->
        json_error(conn, 400, :unknown, "This homeserver does not support thumbnailing #{type} files")

      error ->
        handle_error(conn, error)
    end
  end

  def upload(conn, %MatrixContentURI{} = mxc) do
    user_id = conn.assigns.user_id

    case ContentRepo.try_upload(mxc, user_id, fn -> parse_body(conn) end) do
      {:ok, ^mxc, conn} ->
        json(conn, %{content_uri: mxc})

      {:error, :already_uploaded} ->
        json_error(conn, 409, :endpoint_error, [:cannot_overwrite_media, @overwrite_error_msg])

      {:error, {:quota_reached, quota_kind}} ->
        quota_reached_error(conn, quota_kind, user_id)

      {:error, :not_found} ->
        halting_json_error(conn, 403, :forbidden, @must_reserve_error_msg)

      {:error, :too_large, conn} ->
        msg = "Cannot upload files larger than #{ContentRepo.friendly_bytes(ContentRepo.max_upload_size_bytes())}"
        halting_json_error(conn, 413, :endpoint_error, [:too_large, msg])

      {:error, posix} ->
        Logger.error("Error saving upload to file: #{inspect(posix)}")

        json_error(conn, 500, :unknown, @unknown_error_msg)
    end
  end

  def upload(conn, %{"server_name" => server_name, "media_id" => media_id}) do
    case MatrixContentURI.new(server_name, media_id) do
      {:ok, %MatrixContentURI{} = mxc} ->
        upload(conn, mxc)

      {:error, error} when error in ~w|invalid_server_name invalid_media_id invalid_scheme|a ->
        halting_json_error(conn, 400, :endpoint_error, [:bad_param, "Invalid content URI"])
    end
  end

  def upload(conn, _params) do
    user_id = conn.assigns.user_id

    case ContentRepo.create(user_id) do
      {:ok, %MatrixContentURI{} = mxc, _created_at} -> upload(conn, mxc)
      {:error, {:quota_reached, quota_kind}} -> conn |> quota_reached_error(quota_kind, user_id) |> halt()
    end
  end

  def create(conn, _params) do
    user_id = conn.assigns.user_id

    case ContentRepo.create(user_id) do
      {:ok, mxc, created_at} ->
        json(conn, %{
          content_uri: mxc,
          unused_expires_at: DateTime.to_unix(created_at, :millisecond) + ContentRepo.unused_mxc_uris_expire_in_ms()
        })

      {:error, {:quota_reached, :max_reserved}} ->
        Logger.info("MEDIA QUOTA REACHED max_reserved: #{user_id} tried to upload a file after reaching a limit")

        json_error(conn, 429, :limit_exceeded, [
          ContentRepo.unused_mxc_uris_expire_in_ms(),
          "You have too many pending uploads. Ensure all previous uploads succeed before trying again"
        ])

      {:error, {:quota_reached, quota_kind}} ->
        quota_reached_error(conn, quota_kind, user_id)
    end
  end

  ### HELPERS / PLUGS ###

  defp parse_mxc(conn, _opts) do
    %{"server_name" => server_name, "media_id" => media_id} = conn.assigns.request

    case MatrixContentURI.new(server_name, media_id) do
      {:ok, %MatrixContentURI{} = mxc} -> assign(conn, :mxc, mxc)
      {:error, reason} -> halting_json_error(conn, 400, :endpoint_error, [:bad_param, "Malformed MXC URI: #{reason}"])
    end
  end

  defp handle_error(conn, error) do
    case error do
      {:error, :not_found} -> halting_json_error(conn, 404, :not_found, "File not found")
      {:error, :not_yet_uploaded} -> halting_not_yet_uploaded_error(conn)
      {:error, :too_large} -> halting_json_error(conn, 502, :endpoint_error, [:too_large, "File too large"])
    end
  end

  defp parse_body(conn) do
    limit = ContentRepo.max_upload_size_bytes()
    tmp_path = Plug.Upload.random_file!("user_upload")

    File.open!(tmp_path, [:binary, :raw, :write], fn file ->
      parse_body(conn, tmp_path, file, limit, {0, :crypto.hash_init(:sha256)})
    end)
  end

  defp parse_body(conn, tmp_path, file, limit, {size, sha256_state}) do
    case read_body(conn) do
      {_, body, conn} when byte_size(body) + size > limit ->
        {:error, :too_large, conn}

      {:ok, body, conn} ->
        :ok = IO.binwrite(file, body)
        hash = sha256_state |> :crypto.hash_update(body) |> :crypto.hash_final() |> Base.encode16(case: :lower)
        filename = Map.get(conn.params, "filename", "Uploaded File")
        file_info = ContentRepo.new_file_info(conn.assigns.file_type, size + byte_size(body), hash, filename)

        {:ok, file_info, tmp_path, conn}

      {:more, body, conn} ->
        :ok = IO.binwrite(file, body)
        parse_body(conn, tmp_path, file, limit, {size + byte_size(body), :crypto.hash_update(sha256_state, body)})

      {:error, reason} ->
        Logger.error("Error parsing body of uploaded file: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_mime(conn, _params) do
    mime_type =
      case get_req_header(conn, "content-type") do
        [] -> "application/octet-stream"
        [content_type] -> content_type
      end

    if mime_type in ContentRepo.allowed_mimes() do
      case MIME.extensions(mime_type) do
        [] -> halting_json_error(conn, 403, :forbidden, ["unknown file type"])
        [_ext | _] = extensions -> assign(conn, :file_type, extensions |> Enum.sort() |> hd())
      end
    else
      halting_json_error(conn, 403, :forbidden, ["#{mime_type} files are not allowed"])
    end
  end

  @quota_reached_error_msg "You have uploaded too many files. Contact the server admin if you believe this is a mistake."
  defp quota_reached_error(conn, quota_kind, user_id) do
    Logger.info("MEDIA QUOTA REACHED #{quota_kind}: #{user_id} tried to upload a file after reaching a limit")

    json_error(conn, 403, :forbidden, @quota_reached_error_msg)
  end

  defp halting_not_yet_uploaded_error(conn) do
    halting_json_error(conn, 504, :endpoint_error, [:not_yet_uploaded, "File has not yet been uploaded"])
  end

  defp content_types_to_inline do
    ~w|
      text/css
      text/plain
      text/csv
      application/json
      application/ld+json
      image/jpeg
      image/gif
      image/png
      image/apng
      image/webp
      image/avif
      video/mp4
      video/webm
      video/ogg
      video/quicktime
      audio/mp4
      audio/webm
      audio/aac
      audio/mpeg
      audio/ogg
      audio/wave
      audio/wav
      audio/x-wav
      audio/x-pn-wav
      audio/flac
      audio/x-flac
    |
  end
end
