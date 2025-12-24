defmodule RadioBeamWeb.ContentRepoController do
  @moduledoc """
  Endpoints for retrieving and uploading media and files
  """
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [json_error: 4, halting_json_error: 4]

  alias RadioBeam.ContentRepo.Upload.FileInfo
  alias RadioBeam.ContentRepo.Upload
  alias RadioBeam.ContentRepo.MatrixContentURI
  alias RadioBeam.ContentRepo.Thumbnail
  alias RadioBeam.ContentRepo
  alias RadioBeam.User
  alias RadioBeamWeb.Schemas.ContentRepo, as: ContentRepoSchema

  require Logger

  plug RadioBeamWeb.Plugs.EnforceSchema, [mod: ContentRepoSchema] when action in [:thumbnail, :download]
  plug :parse_mxc_and_fetch_upload when action in [:thumbnail, :download]

  plug :get_or_reserve_upload when action == :upload
  plug :parse_mime when action == :upload
  plug :parse_body when action == :upload

  @must_reserve_error_msg "You must reserve a content URI first"
  @unknown_error_msg "An unknown error occurred while uploading your file - please try again"
  @overwrite_error_msg "A file already exists under this URI"

  def config(conn, _params) do
    json(conn, %{"m.upload.size" => ContentRepo.max_upload_size_bytes()})
  end

  def download(conn, params) do
    upload = conn.assigns.upload

    content_type = MIME.type(upload.file.type)
    disposition = if content_type in content_types_to_inline(), do: :inline, else: :attachment

    send_download(conn, {:file, ContentRepo.upload_file_path(upload)},
      filename: Map.get(params, "filename", upload.file.filename),
      content_type: content_type,
      disposition: disposition
    )
  end

  def thumbnail(conn, _params) do
    request = conn.assigns.request
    upload = conn.assigns.upload

    with {:ok, spec} <- Thumbnail.coerce_spec(request["width"], request["height"], request["method"]),
         {:ok, thumbnail_path} <- ContentRepo.get_thumbnail(upload, spec) do
      send_download(conn, {:file, thumbnail_path},
        filename: "thumbnail.#{upload.file.type}",
        content_type: MIME.type(upload.file.type),
        disposition: :inline
      )
    else
      {:error, :invalid_spec} ->
        json_error(conn, 400, :bad_json, "The given thumbnail width, height, or method is not supported")

      {:error, {:cannot_thumbnail, type}} ->
        json_error(conn, 400, :unknown, "This homeserver does not support thumbnailing #{type} files")
    end
  end

  def upload(conn, _params) do
    %User{} = user = conn.assigns.session.user
    %Upload{} = upload = conn.assigns.upload
    %FileInfo{} = file_info = conn.assigns.file_info
    tmp_path = conn.assigns.tmp_upload_path

    case ContentRepo.upload(upload, file_info, tmp_path) do
      {:ok, _path} ->
        json(conn, %{content_uri: upload.id})

      {:error, :already_uploaded} ->
        json_error(conn, 409, :endpoint_error, [:cannot_overwrite_media, @overwrite_error_msg])

      {:error, {:quota_reached, quota_kind}} ->
        quota_reached_error(conn, quota_kind, user)

      {:error, posix} ->
        Logger.error("Error saving upload to file: #{inspect(posix)}")

        json_error(conn, 500, :unknown, @unknown_error_msg)
    end
  end

  def create(conn, _params) do
    %User{} = user = conn.assigns.session.user

    case ContentRepo.create(user) do
      {:ok, upload} ->
        json(conn, %{
          content_uri: upload.id,
          unused_expires_at:
            DateTime.to_unix(upload.inserted_at, :millisecond) + ContentRepo.unused_mxc_uris_expire_in_ms()
        })

      {:error, {:quota_reached, :max_reserved}} ->
        Logger.info("MEDIA QUOTA REACHED max_reserved: #{user} tried to upload a file after reaching a limit")

        json_error(conn, 429, :limit_exceeded, [
          ContentRepo.unused_mxc_uris_expire_in_ms(),
          "You have too many pending uploads. Ensure all previous uploads succeed before trying again"
        ])

      {:error, {:quota_reached, quota_kind}} ->
        quota_reached_error(conn, quota_kind, user)
    end
  end

  ### HELPERS / PLUGS ###

  defp parse_mxc_and_fetch_upload(conn, _opts) do
    %{"server_name" => server_name, "media_id" => media_id} = request = conn.assigns.request

    timeout =
      case Map.fetch(request, "timeout_ms") do
        {:ok, timeout} -> timeout
        :error -> ContentRepo.max_wait_for_download_ms()
      end

    with {:ok, %MatrixContentURI{} = mxc} <- MatrixContentURI.new(server_name, media_id),
         {:ok, %Upload{id: ^mxc, file: %FileInfo{}} = upload} <- ContentRepo.get(mxc, timeout: timeout) do
      assign(conn, :upload, upload)
    else
      {:error, :not_found} -> halting_json_error(conn, 404, :not_found, "File not found")
      {:error, :not_yet_uploaded} -> halting_not_yet_uploaded_error(conn)
      {:error, :too_large} -> halting_json_error(conn, 502, :endpoint_error, [:too_large, "File too large"])
      {:error, reason} -> halting_json_error(conn, 400, :endpoint_error, [:bad_param, "Malformed MXC URI: #{reason}"])
    end
  end

  defp get_or_reserve_upload(%{params: %{"server_name" => server_name, "media_id" => media_id}} = conn, _) do
    %User{id: uploader_id} = conn.assigns.session.user

    with {:ok, %MatrixContentURI{} = mxc} <- MatrixContentURI.new(server_name, media_id),
         {:ok, %Upload{id: ^mxc, file: :reserved, uploaded_by_id: ^uploader_id} = upload} <-
           RadioBeam.Database.fetch(Upload, mxc) do
      assign(conn, :upload, upload)
    else
      {:error, :not_found} ->
        halting_json_error(conn, 403, :forbidden, @must_reserve_error_msg)

      {:error, :too_large} ->
        halting_json_error(conn, 502, :endpoint_error, [:too_large, "File too large to download"])

      {:error, error} when error in [:invalid_server_name, :invalid_media_id] ->
        halting_json_error(conn, 400, :endpoint_error, [:bad_param, "Invalid content URI"])

      {:ok, %Upload{file: :reserved}} ->
        halting_json_error(conn, 403, :forbidden, @must_reserve_error_msg)

      {:ok, %Upload{}} ->
        halting_json_error(conn, 409, :endpoint_error, [:cannot_overwrite_media, @overwrite_error_msg])
    end
  end

  defp get_or_reserve_upload(conn, _opts) do
    %User{} = user = conn.assigns.session.user

    case ContentRepo.create(user) do
      {:ok, upload} -> assign(conn, :upload, upload)
      {:error, {:quota_reached, quota_kind}} -> conn |> quota_reached_error(quota_kind, user) |> halt()
    end
  end

  defp parse_body(conn, _opts) do
    limit = ContentRepo.max_upload_size_bytes()
    tmp_path = Plug.Upload.random_file!("user_upload")

    File.open!(tmp_path, [:binary, :raw, :write], fn file ->
      conn
      |> assign(:tmp_upload_path, tmp_path)
      |> parse_body(file, limit, {0, :crypto.hash_init(:sha256)})
    end)
  end

  defp parse_body(conn, file, limit, {size, sha256_state}) do
    case read_body(conn) do
      {_, body, conn} when byte_size(body) + size > limit ->
        halting_json_error(conn, 413, :endpoint_error, [
          :too_large,
          "Cannot upload files larger than #{ContentRepo.friendly_bytes(limit)}"
        ])

      {:ok, body, conn} ->
        :ok = IO.binwrite(file, body)
        hash = sha256_state |> :crypto.hash_update(body) |> :crypto.hash_final() |> Base.encode16(case: :lower)
        filename = Map.get(conn.params, "filename", "Uploaded File")
        file_info = FileInfo.new(conn.assigns.file_type, size + byte_size(body), hash, filename)

        assign(conn, :file_info, file_info)

      {:more, body, conn} ->
        :ok = IO.binwrite(file, body)
        parse_body(conn, file, limit, {size + byte_size(body), :crypto.hash_update(sha256_state, body)})

      {:error, reason} ->
        Logger.error("Error parsing body of uploaded file: #{inspect(reason)}")

        halting_json_error(conn, 500, :unknown, @unknown_error_msg)
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
  defp quota_reached_error(conn, quota_kind, user) do
    Logger.info("MEDIA QUOTA REACHED #{quota_kind}: #{user} tried to upload a file after reaching a limit")

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
