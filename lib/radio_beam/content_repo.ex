defmodule RadioBeam.ContentRepo do
  alias RadioBeam.User
  alias RadioBeam.ContentRepo.MatrixContentURI
  alias RadioBeam.ContentRepo.Upload

  def allowed_mimes, do: Application.fetch_env!(:radio_beam, __MODULE__)[:allowed_mimes]
  def max_upload_size_bytes, do: Application.fetch_env!(:radio_beam, __MODULE__)[:single_file_max_bytes]
  def unused_mxc_uris_expire_in_ms, do: Application.fetch_env!(:radio_beam, __MODULE__)[:unused_mxc_uris_expire_in_ms]
  def user_upload_limits, do: Application.fetch_env!(:radio_beam, __MODULE__)[:users]
  def path(), do: Application.fetch_env!(:radio_beam, __MODULE__)[:dir]

  @doc """
  Prints a user-friendly representation of bytes

    iex> RadioBeam.ContentRepo.friendly_bytes(500)
    "500 bytes"
    iex> RadioBeam.ContentRepo.friendly_bytes(5_000_000)
    "5MB"
    iex> RadioBeam.ContentRepo.friendly_bytes(5_000_000_000)
    "5GB"
  """
  def friendly_bytes(bytes) when bytes < 1_000, do: "#{bytes} bytes"
  def friendly_bytes(bytes) when bytes < 1_000_000, do: "#{div(bytes, 1_000)}KB"
  def friendly_bytes(bytes) when bytes < 1_000_000_000, do: "#{div(bytes, 1_000_000)}MB"
  def friendly_bytes(bytes), do: "#{div(bytes, 1_000_000_000)}GB"

  # TODO: a periodic job should clean up expired reserved URIs
  def reserve(%MatrixContentURI{} = mxc, %User{} = reserver) do
    %{max_pending: max_pending} = user_upload_limits()

    fn ->
      cond do
        Upload.get_num_pending_uploadsT(reserver.id) >= max_pending -> {:quota_reached, :max_pending}
        not is_nil(Upload.getT(mxc)) -> :already_reserved
        :else -> mxc |> Upload.new_pending(reserver) |> Memento.Query.write()
      end
    end
    |> Memento.transaction()
    |> case do
      {:ok, %Upload{} = upload} -> {:ok, upload}
      {:ok, error} -> {:error, error}
      result -> result
    end
  end

  def save_upload(%Upload{} = upload, iodata, path \\ path()) do
    fn ->
      with :ok <- validate_perms(upload.uploaded_by_id, upload.byte_size),
           :ok <- validate_mime(upload.mime_type),
           upload_path = path_for_upload(upload, path),
           :ok <- upload_path |> Path.dirname() |> File.mkdir_p(),
           {:ok, ^upload_path} <- write_upload(upload, upload_path, iodata) do
        upload_path
      end
    end
    |> Memento.transaction()
    |> case do
      {:ok, {:error, _} = error} -> error
      result -> result
    end
  end

  defp write_upload(upload, path, iodata) do
    # the same file (assuming we're using the sha256 of its content in its path) 
    # was uploaded before - let's just point to that and save some space
    if File.exists?(path) do
      Memento.Query.write(upload)
      path
    else
      File.open(path, [:binary, :raw, :write], fn file ->
        IO.binwrite(file, iodata)
        Memento.Query.write(upload)
        path
      end)
    end
  end

  defp validate_perms(user_id, pending_upload_size) do
    {num_uploads, total_uploaded_bytes} =
      Upload
      |> Memento.Query.select_raw(Upload.all_user_upload_sizes_ms(user_id), coerce: false)
      |> Enum.reduce({0, pending_upload_size}, fn upload_bytes, {num_uploads, total_uploaded_bytes} ->
        {num_uploads + 1, total_uploaded_bytes + upload_bytes}
      end)

    %{max_files: max_files, max_bytes: max_bytes} = user_upload_limits()

    cond do
      num_uploads >= max_files -> {:error, {:quota_reached, :max_files}}
      total_uploaded_bytes >= max_bytes -> {:error, {:quota_reached, :max_bytes}}
      :else -> :ok
    end
  end

  defp validate_mime(mime_type) do
    if mime_type in allowed_mimes(), do: :ok, else: {:error, :invalid_mime_type}
  end

  defp path_for_upload(%Upload{} = upload, path) do
    case path do
      :default ->
        Path.join([Application.app_dir(:radio_beam), "priv/static/media", Upload.path_for(upload)])

      path when is_binary(path) ->
        Path.join([path, Upload.path_for(upload)])
    end
  end
end
