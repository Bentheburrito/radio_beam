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

        {:error, {:quota_reached, quota_kind}} ->
          Logger.info(
            "MEDIA QUOTA REACHED #{quota_kind}: #{user} tried to upload a file after reaching their upload limit"
          )

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
        |> json(Errors.forbidden("Cannot upload files larger than #{ContentRepo.friendly_bytes(limit)}"))

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
end
