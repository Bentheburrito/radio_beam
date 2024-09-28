defmodule RadioBeamWeb.ContentRepoController do
  @moduledoc """
  Endpoints for retrieving and uploading media and files
  """
  use RadioBeamWeb, :controller

  alias RadioBeam.ContentRepo.Upload
  alias RadioBeam.ContentRepo.MatrixContentURI
  alias RadioBeam.Errors
  alias RadioBeam.ContentRepo
  alias RadioBeam.User

  require Logger

  plug RadioBeamWeb.Plugs.Authenticate

  def config(conn, _params) do
    json(conn, %{"m.upload.size" => ContentRepo.max_upload_size_bytes()})
  end

  def download(conn, %{"server_name" => server_name, "media_id" => media_id} = params) do
    # TODO: create a Schema for this
    timeout =
      with %{"timeout" => timeout_str} <- params,
           {:ok, timeout} <- RadioBeamWeb.Schemas.as_integer(timeout_str) do
        timeout
      else
        _ -> ContentRepo.max_wait_for_download_ms()
      end

    with {:ok, %MatrixContentURI{} = mxc} <- MatrixContentURI.new(server_name, media_id),
         {:ok, %Upload{id: ^mxc} = upload, upload_path} <- ContentRepo.get(mxc, timeout) do
      conn
      |> put_resp_header("content-type", upload.mime_type)
      |> put_resp_header("content-disposition", Map.get(params, "filename", upload.filename))
      |> send_file(200, upload_path)
    else
      {:error, :not_found} ->
        conn |> put_status(404) |> json(Errors.not_found("File not found"))

      {:error, :not_yet_uploaded} ->
        conn |> put_status(504) |> json(Errors.endpoint_error(:not_yet_uploaded, "File has not yet been uploaded"))

      {:error, :too_large} ->
        conn |> put_status(502) |> json(Errors.endpoint_error(:too_large, "File too large"))

      {:error, invalid_mxc_reason} ->
        conn |> put_status(400) |> json(Errors.endpoint_error(:bad_param, "Malformed MXC URI: #{invalid_mxc_reason}"))
    end
  end

  def upload(conn, %{"server_name" => server_name, "media_id" => media_id}) do
    %User{id: uploader_id} = conn.assigns.user

    with {:ok, %MatrixContentURI{} = mxc} <- MatrixContentURI.new(server_name, media_id),
         {:ok, %Upload{id: ^mxc, sha256: :pending, uploaded_by_id: ^uploader_id}} <- Upload.get(mxc) do
      conn |> assign(:mxc, mxc) |> upload(%{})
    else
      {:error, :not_found} -> must_reserve(conn)
      {:error, _error} -> conn |> put_status(400) |> json(Errors.endpoint_error(:bad_param, "Invalid content URI"))
      {:ok, %Upload{sha256: :pending}} -> must_reserve(conn)
      {:ok, %Upload{}} -> cannot_overwrite_media(conn)
    end
  end

  @unknown_error_msg "An unknown error has occurred while uploading your file - please try again"
  @too_many_uploads_msg "You have uploaded too many files. Contact the server admin if you believe this is a mistake."
  def upload(conn, params) do
    %User{} = user = conn.assigns.user

    content_type =
      case get_req_header(conn, "content-type") do
        [] -> "application/octet-stream"
        [content_type] -> content_type
      end

    filename = Map.get(params, "filename", "Uploaded File")

    with {:ok, body_io_list, conn} <- parse_body(conn, ContentRepo.max_upload_size_bytes()) do
      mxc = Map.get_lazy(conn.assigns, :mxc, fn -> MatrixContentURI.new!() end)

      %Upload{} = upload = Upload.new(mxc, content_type, user, body_io_list, filename)

      case ContentRepo.save_upload(upload, body_io_list) do
        {:ok, _path} ->
          json(conn, %{content_uri: mxc})

        {:error, :invalid_mime_type} ->
          conn
          |> put_status(403)
          |> json(Errors.forbidden("This homeserver does not allow files of that kind"))

        {:error, :already_uploaded} ->
          cannot_overwrite_media(conn)

        {:error, {:quota_reached, quota_kind}} ->
          Logger.info("MEDIA QUOTA REACHED #{quota_kind}: #{user} tried to upload a file after reaching a limit")

          conn
          |> put_status(403)
          |> json(Errors.forbidden(@too_many_uploads_msg))

        {:error, posix} ->
          Logger.error("Error saving upload to file: #{inspect(posix)}")

          conn
          |> put_status(500)
          |> json(Errors.unknown(@unknown_error_msg))
      end
    end
  end

  def create(conn, _params) do
    # check if user already has <config value max num> pending uploads
    %User{} = user = conn.assigns.user
    mxc = MatrixContentURI.new!()

    case ContentRepo.reserve(mxc, user) do
      {:ok, upload} ->
        json(conn, %{
          content_uri: mxc,
          expires_in: DateTime.to_unix(upload.inserted_at, :millisecond) + ContentRepo.unused_mxc_uris_expire_in_ms()
        })

      {:error, {:quota_reached, :max_pending}} ->
        conn
        |> put_status(429)
        |> json(
          Errors.limit_exceeded(
            ContentRepo.unused_mxc_uris_expire_in_ms(),
            "You have too many pending uploads. Ensure all previous uploads succeed before trying again"
          )
        )
    end
  end

  defp parse_body(conn, limit), do: parse_body(conn, limit, "")

  defp parse_body(conn, limit, body_io_list) do
    # TODO: should stream this to a temp file like Plug.Upload does - keeping large
    #       uploads in memory is bad
    case read_body(conn) do
      {_, body, conn} when byte_size(body) > limit ->
        conn
        |> put_status(413)
        |> json(
          Errors.endpoint_error(:too_large, "Cannot upload files larger than #{ContentRepo.friendly_bytes(limit)}")
        )

      {:ok, body, conn} ->
        {:ok, [body_io_list | [body]], conn}

      {:more, body, conn} ->
        parse_body(conn, limit - byte_size(body), [body_io_list | [body]])

      {:error, reason} ->
        Logger.error("Error parsing body of uploaded file: #{inspect(reason)}")

        conn
        |> put_status(500)
        |> json(Errors.unknown(@unknown_error_msg))
    end
  end

  defp cannot_overwrite_media(conn) do
    conn
    |> put_status(409)
    |> json(Errors.endpoint_error(:cannot_overwrite_media, "A file already exists under this URI"))
  end

  defp must_reserve(conn), do: conn |> put_status(403) |> json(Errors.forbidden("You must reserve a content URI first"))
end
