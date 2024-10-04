defmodule RadioBeam.ContentRepo do
  import Memento.Transaction, only: [abort: 1]

  alias Phoenix.PubSub
  alias RadioBeam.User
  alias RadioBeam.ContentRepo.MatrixContentURI
  alias RadioBeam.ContentRepo.Upload
  alias RadioBeam.ContentRepo.Upload.FileInfo
  alias RadioBeam.PubSub, as: PS

  @type quota_kind() :: :max_reserved | :max_files | :max_bytes

  @type get_opt() :: {:timeout, non_neg_integer()} | {:repo_path, Path.t()}
  @type get_opts() :: [get_opt()]

  def allowed_mimes, do: Application.fetch_env!(:radio_beam, __MODULE__)[:allowed_mimes]
  def max_upload_size_bytes, do: Application.fetch_env!(:radio_beam, __MODULE__)[:single_file_max_bytes]
  def max_wait_for_download_ms, do: Application.fetch_env!(:radio_beam, __MODULE__)[:max_wait_for_download_ms]
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

  @doc """
  Gets an `%Upload{}` from the content repository by its `mxc://`. This
  function will double-check if the file is larger than
  `max_upload_size_bytes`, returning `{:error, :too_large}` if so.

  TODO: check if the server_name is this server, GET from origin server if
  remote media and within max size
  """
  @spec get(MatrixContentURI.t(), get_opts()) ::
          {:ok, Upload.t(), Path.t()} | {:error, :too_large | :not_yet_uploaded | any()}
  def get(%MatrixContentURI{} = mxc, opts) do
    max_size_bytes = max_upload_size_bytes()
    repo_path = Keyword.get_lazy(opts, :repo_path, &path/0)
    timeout = Keyword.get_lazy(opts, :timeout, &max_wait_for_download_ms/0)
    PubSub.subscribe(PS, PS.file_uploaded(mxc))

    case Upload.get(mxc) do
      {:ok, %Upload{file: %FileInfo{byte_size: byte_size}}} when byte_size > max_size_bytes -> {:error, :too_large}
      {:ok, %Upload{file: %FileInfo{}} = upload} -> {:ok, upload, path_for_upload(upload, repo_path)}
      {:ok, %Upload{file: :reserved}} -> await_upload(timeout, repo_path)
      {:error, _} = error -> error
    end
  end

  defp await_upload(timeout, repo_path) do
    receive do
      {:file_uploaded, %Upload{file: %FileInfo{}} = upload} -> {:ok, upload, path_for_upload(upload, repo_path)}
    after
      timeout -> {:error, :not_yet_uploaded}
    end
  end

  @doc """
  Creates an `%Upload{}` entry in the content repository, as long as the user
  hasn't met an upload quota.

  TODO: a periodic job should clean up expired reserved URIs
  """
  @spec create(User.t()) :: {:ok, Upload.t()} | {:error, {:quota_reached, :max_reserved | :max_files} | any()}
  def create(%User{} = reserver) do
    %{max_reserved: max_reserved, max_files: max_files} = user_upload_limits()

    fn ->
      user_upload_counts = Upload.user_upload_countsT(reserver.id)
      reserved_count = Map.get(user_upload_counts, :reserved, 0)
      total_count = Map.get(user_upload_counts, :uploaded, 0) + reserved_count

      cond do
        reserved_count >= max_reserved -> abort({:quota_reached, :max_reserved})
        total_count >= max_files -> abort({:quota_reached, :max_files})
        :else -> reserver |> Upload.new() |> Upload.putT()
      end
    end
    |> Memento.transaction()
    |> case do
      {:ok, %Upload{} = upload} -> {:ok, upload}
      {:error, {:transaction_aborted, reason}} -> {:error, reason}
      result -> result
    end
  end

  @doc """
  Updates an `%Upload{}` previously reserved with `create/1` with the uploaded
  file.
  """
  @spec upload(Upload.t(), FileInfo.t(), Path.t()) ::
          {:ok, Upload.t()} | {:error, :too_large | {:quota_reached, :max_bytes} | File.posix()}
  def upload(%Upload{file: :reserved} = upload, %FileInfo{} = file_info, tmp_upload_path, repo_path \\ path()) do
    fn ->
      with :ok <- validate_upload_size(upload.uploaded_by_id, file_info.byte_size),
           %Upload{} = upload <- upload |> Upload.put_file(file_info) |> Upload.putT(),
           :ok <- copy_upload_if_no_exists(tmp_upload_path, path_for_upload(upload, repo_path)) do
        PubSub.broadcast(PS, PS.file_uploaded(upload.id), {:file_uploaded, upload})
        upload
      else
        error -> abort(error)
      end
    end
    |> Memento.transaction()
    |> case do
      {:error, {:transaction_aborted, error}} -> error
      result -> result
    end
  end

  # copies the uploaded file from a temp path to the content repo's directory,
  # as long as the upload doesn't already exist
  defp copy_upload_if_no_exists(tmp_upload_path, upload_path) do
    with :ok <- upload_path |> Path.dirname() |> File.mkdir_p(),
         :ok <- File.cp(tmp_upload_path, upload_path, on_conflict: fn _, _ -> false end) do
      :ok
    end
  end

  defp validate_upload_size(uploader_id, upload_size) do
    cond do
      upload_size > max_upload_size_bytes() ->
        {:error, :too_large}

      Upload.user_total_uploaded_bytesT(uploader_id) + upload_size > user_upload_limits().max_bytes ->
        {:error, {:quota_reached, :max_bytes}}

      :else ->
        :ok
    end
  end

  defp path_for_upload(%Upload{} = upload, repo_path) do
    case repo_path do
      :default -> Path.join([Application.app_dir(:radio_beam), "priv/static/media", Upload.path_for(upload)])
      path when is_binary(path) -> Path.join([path, Upload.path_for(upload)])
    end
  end
end
