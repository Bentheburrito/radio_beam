defmodule RadioBeam.ContentRepo do
  @moduledoc """
  The content/media repository. Manages user-uploaded files, authorizing based
  on configured limits.
  """

  # use Boundary, deps: [], exports: []

  alias RadioBeam.ContentRepo.Database
  alias RadioBeam.User
  alias RadioBeam.ContentRepo.MatrixContentURI
  alias RadioBeam.ContentRepo.Thumbnail
  alias RadioBeam.ContentRepo.Upload
  alias RadioBeam.ContentRepo.Upload.FileInfo
  alias RadioBeam.PubSub, as: PS

  @type quota_kind() :: :max_reserved | :max_files | :max_bytes

  @type get_opt() :: {:timeout, non_neg_integer()} | {:repo_path, Path.t()}
  @type get_opts() :: [get_opt()]

  @type thumbnail_info_for_opt() :: {:animated?, boolean()} | {:repo_path, Path.t()}
  @type thumbnail_info_for_opts() :: [get_opt()]

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
  Returns info to download a previously-uploaded file from the content
  repository by its `mxc://`. This function will double-check if the file is
  larger than `max_upload_size_bytes`, returning `{:error, :too_large}` if so.

  Blocks if the file is not yet uploaded, returning the info as soon as it is
  uploaded, or the given timeout in the `:timeout` opt passes. If a `:timeout`
  is not given, the timeout defaults to the configured
  `max_wait_for_download_ms`.

  TODO: check if the server_name is this server, GET from origin server if
  remote media and within max size
  """
  def download_info_for(%MatrixContentURI{} = mxc, opts) do
    with {:ok, %Upload{id: ^mxc, file: %FileInfo{} = file} = upload} <- get_upload(mxc, opts) do
      repo_path = Keyword.get_lazy(opts, :repo_path, &path/0)

      {:ok, file.type, file.filename, upload_file_path(upload, repo_path)}
    end
  end

  @spec get_upload(MatrixContentURI.t(), get_opts()) ::
          {:ok, Upload.t()} | {:error, :too_large | :not_yet_uploaded | any()}
  defp get_upload(%MatrixContentURI{} = mxc, opts) do
    max_size_bytes = max_upload_size_bytes()
    timeout = Keyword.get_lazy(opts, :timeout, &max_wait_for_download_ms/0)
    PS.subscribe(PS.file_uploaded(mxc))

    case Database.fetch_upload(mxc) do
      {:ok, %Upload{file: %FileInfo{byte_size: byte_size}}} when byte_size > max_size_bytes -> {:error, :too_large}
      {:ok, %Upload{file: %FileInfo{}} = upload} -> {:ok, upload}
      {:ok, %Upload{file: :reserved}} -> await_upload(timeout)
      {:error, _} = error -> error
    end
  end

  defp await_upload(timeout) do
    receive do
      {:file_uploaded, %Upload{file: %FileInfo{}} = upload} -> {:ok, upload}
    after
      timeout -> {:error, :not_yet_uploaded}
    end
  end

  @thumbnailable_types Thumbnail.allowed_file_types()
  defguardp is_thumbnailable(type) when type in @thumbnailable_types

  @allowed_specs Thumbnail.allowed_specs()
  defguardp is_allowed_spec(spec) when spec in @allowed_specs

  @doc """
  Returns info to download a thumbnail of the given MXC and spec, generating it
  if necessary.

  Blocks if the file is not yet uploaded, returning the info as soon as it is
  uploaded, or the given timeout in the `:timeout` opt passes. If a `:timeout`
  is not given, the timeout defaults to the configured
  `max_wait_for_download_ms`.
  """
  @spec thumbnail_info_for(Upload.t() | MatrixContentURI.t(), Thumbnail.spec(), thumbnail_info_for_opts()) ::
          {:ok, Path.t()}
          | {:error, :not_yet_uploaded | :invalid_spec | {:cannot_thumbnail, String.t()}}
          | (error :: Exception.t())
  def thumbnail_info_for(upload_or_mxc, spec, opts \\ [])

  def thumbnail_info_for(upload_or_mxc, spec, opts) when not is_allowed_spec(spec) do
    with {:ok, spec} <- Thumbnail.coerce_spec(spec), do: thumbnail_info_for(upload_or_mxc, spec, opts)
  end

  def thumbnail_info_for(%MatrixContentURI{} = mxc, spec, opts) do
    with {:ok, %Upload{id: ^mxc, file: %FileInfo{}} = upload} <- get_upload(mxc, opts) do
      thumbnail_info_for(upload, spec, opts)
    end
  end

  def thumbnail_info_for(%Upload{file: %FileInfo{type: type}} = upload, spec, opts)
      when is_thumbnailable(type) and is_allowed_spec(spec) do
    repo_path = Keyword.get_lazy(opts, :repo_path, &path/0)

    thumbnail_path = thumbnail_file_path(upload, spec, repo_path)

    if not File.exists?(thumbnail_path) do
      animated? = Keyword.get(opts, :animated?, false)
      generate_thumbnail(upload, spec, animated?, thumbnail_path, repo_path)
    end

    {:ok, type, upload.file.filename, thumbnail_path}
  rescue
    error -> error
  end

  def thumbnail_info_for(%Upload{file: :reserved}, _spec, _opts), do: {:error, :not_yet_uploaded}
  def thumbnail_info_for(%Upload{file: nil}, _spec, _opts), do: {:error, :not_yet_uploaded}
  def thumbnail_info_for(%Upload{file: %{type: type}}, _spec, _opts), do: {:error, {:cannot_thumbnail, type}}

  defp generate_thumbnail(%Upload{} = upload, spec, animated?, thumbnail_path, repo_path) do
    upload.file.type
    |> Thumbnail.new!()
    |> Thumbnail.load_source_from_path!(upload_file_path(upload, repo_path))
    |> Thumbnail.generate!(spec, animated?)
    |> Thumbnail.save_to_path!(thumbnail_path)
  end

  @doc """
  Creates an `%Upload{}` entry in the content repository, as long as the user
  hasn't met an upload quota.

  TODO: a periodic job should clean up expired reserved URIs
  """
  @spec create(User.id()) ::
          {:ok, MatrixContentURI.t(), DateTime.t()} | {:error, {:quota_reached, :max_reserved | :max_files} | any()}
  def create(reserver_id) do
    Database.with_user_upload_counts(reserver_id, fn user_upload_counts ->
      reserved_count = Map.get(user_upload_counts, :reserved, 0)
      total_count = Map.get(user_upload_counts, :uploaded, 0) + reserved_count

      with {:ok, %Upload{} = upload} <- try_new_reserved(reserver_id, reserved_count, total_count),
           :ok <- Database.upsert_upload(upload) do
        {:ok, upload.id, upload.created_at}
      end
    end)
  end

  defp try_new_reserved(reserver_id, reserved_count, total_count) do
    %{max_reserved: max_reserved, max_files: max_files} = user_upload_limits()

    cond do
      reserved_count >= max_reserved -> {:error, {:quota_reached, :max_reserved}}
      total_count >= max_files -> {:error, {:quota_reached, :max_files}}
      :else -> {:ok, Upload.new(reserver_id)}
    end
  end

  defdelegate new_file_info(type, byte_size, hash, filename), to: FileInfo, as: :new

  @doc """
  Uploads the contents of a previously reserved file to the content repository.

  This function first validates that `reserver_id` previously reserved an
  upload under `mxc` via `create/1`, then invokes `accept_file_fxn` to initiate
  the download. After the download completes, final verification that the user
  has not exceeded any quotas is performed. Finally, the uploaded file content
  is copied into the repository.

  `accept_file_fxn` should return `{:ok, %FileInfo{}, path_to_file,
  context_to_return}`. The file info and path are required to check quotas and
  save metadata to the `ContentRepo.Database`. `context_to_return` is simply
  returned by this function untouched.
  """
  def try_upload(%MatrixContentURI{} = mxc, reserver_id, accept_file_fxn, repo_path \\ path()) do
    with {:ok, %Upload{} = upload} <- Database.fetch_upload(mxc),
         :ok <- validate_reservation(upload, reserver_id),
         {:ok, %FileInfo{} = file_info, tmp_path, acceptor_context} <- accept_file_fxn.(),
         {:ok, %Upload{id: ^mxc}} <- upload(upload, file_info, tmp_path, repo_path) do
      {:ok, mxc, acceptor_context}
    end
  end

  defp validate_reservation(%Upload{file: :reserved, uploaded_by_id: reserver_id}, reserver_id), do: :ok
  defp validate_reservation(%Upload{file: %FileInfo{}}, _reserver_id), do: {:error, :already_uploaded}
  defp validate_reservation(_upload, _reserver_id), do: {:error, :not_found}

  @spec upload(Upload.t(), FileInfo.t(), Path.t(), Path.t()) ::
          {:ok, Upload.t()} | {:error, :too_large | {:quota_reached, :max_bytes} | File.posix()}
  defp upload(%Upload{file: :reserved} = upload, %FileInfo{} = file_info, tmp_upload_path, repo_path) do
    Database.with_user_total_uploaded_bytes(upload.uploaded_by_id, fn user_total_uploaded_bytes ->
      upload = Upload.put_file(upload, file_info)

      with :ok <- validate_upload_size(user_total_uploaded_bytes, file_info.byte_size),
           :ok <- Database.upsert_upload(upload),
           :ok <- copy_upload_if_no_exists(tmp_upload_path, upload_file_path(upload, repo_path)) do
        PS.broadcast(PS.file_uploaded(upload.id), {:file_uploaded, upload})
        {:ok, upload}
      end
    end)
  end

  # copies the uploaded file from a temp path to the content repo's directory,
  # as long as the upload doesn't already exist
  defp copy_upload_if_no_exists(tmp_upload_path, upload_path) do
    with :ok <- upload_path |> Path.dirname() |> File.mkdir_p() do
      File.cp(tmp_upload_path, upload_path, on_conflict: fn _, _ -> false end)
    end
  end

  defp validate_upload_size(user_total_uploaded_bytes, upload_size) do
    cond do
      upload_size > max_upload_size_bytes() ->
        {:error, :too_large}

      user_total_uploaded_bytes + upload_size > user_upload_limits().max_bytes ->
        {:error, {:quota_reached, :max_bytes}}

      :else ->
        :ok
    end
  end

  defp thumbnail_file_path(%Upload{} = upload, {width, height, method}, repo_path) do
    Path.join([
      parse_repo_path(repo_path),
      Base.encode64(upload.id.server_name),
      "#{upload.file.sha256}_#{width}x#{height}_#{method}.#{upload.file.type}"
    ])
  end

  defp upload_file_path(%Upload{} = upload, repo_path) do
    Path.join([
      parse_repo_path(repo_path),
      Base.encode64(upload.id.server_name),
      "#{upload.file.sha256}.#{upload.file.type}"
    ])
  end

  defp parse_repo_path(:default), do: Application.app_dir(:radio_beam)
  defp parse_repo_path(repo_path) when is_binary(repo_path), do: repo_path
end
