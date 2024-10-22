defmodule RadioBeam.ContentRepo do
  @moduledoc """
  The content/media repository. Manages user-uploaded files, authorizing based
  on configured limits.
  """
  alias Phoenix.PubSub
  alias RadioBeam.User
  alias RadioBeam.ContentRepo.MatrixContentURI
  alias RadioBeam.ContentRepo.Thumbnail
  alias RadioBeam.ContentRepo.Upload
  alias RadioBeam.ContentRepo.Upload.FileInfo
  alias RadioBeam.PubSub, as: PS
  alias RadioBeam.Repo

  @type quota_kind() :: :max_reserved | :max_files | :max_bytes

  @type get_opt() :: {:timeout, non_neg_integer()} | {:repo_path, Path.t()}
  @type get_opts() :: [get_opt()]

  @type get_thumbnail_opt() :: {:animated?, boolean()} | {:repo_path, Path.t()}
  @type get_thumbnail_opts() :: [get_opt()]

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
  @spec get(MatrixContentURI.t(), get_opts()) :: {:ok, Upload.t()} | {:error, :too_large | :not_yet_uploaded | any()}
  def get(%MatrixContentURI{} = mxc, opts) do
    max_size_bytes = max_upload_size_bytes()
    timeout = Keyword.get_lazy(opts, :timeout, &max_wait_for_download_ms/0)
    PubSub.subscribe(PS, PS.file_uploaded(mxc))

    case Upload.get(mxc) do
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
  Gets an `%Upload{}`'s thumbnail of the given spec, generating it if
  necessary.
  """
  @spec get_thumbnail(Upload.t(), Thumbnail.spec(), get_thumbnail_opts()) ::
          {:ok, Path.t()}
          | {:error, :not_yet_uploaded | :invalid_spec | {:cannot_thumbnail, String.t()}}
          | (error :: Exception.t())
  def get_thumbnail(upload, spec, opts \\ [])

  def get_thumbnail(%Upload{file: %FileInfo{type: type}} = upload, spec, opts)
      when is_thumbnailable(type) and is_allowed_spec(spec) do
    repo_path = Keyword.get_lazy(opts, :repo_path, &path/0)

    thumbnail_path = thumbnail_file_path(upload, spec, repo_path)

    if not File.exists?(thumbnail_path) do
      animated? = Keyword.get(opts, :animated?, true)
      generate_thumbnail(upload, spec, animated?, thumbnail_path, repo_path)
    end

    {:ok, thumbnail_path}
  rescue
    error -> error
  end

  def get_thumbnail(%Upload{file: :reserved}, _spec, _opts), do: {:error, :not_yet_uploaded}
  def get_thumbnail(%Upload{file: nil}, _spec, _opts), do: {:error, :not_yet_uploaded}
  def get_thumbnail(%Upload{}, spec, _opts) when not is_allowed_spec(spec), do: {:error, :invalid_spec}
  def get_thumbnail(%Upload{file: %{type: type}}, _spec, _opts), do: {:error, {:cannot_thumbnail, type}}

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
  @spec create(User.t()) :: {:ok, Upload.t()} | {:error, {:quota_reached, :max_reserved | :max_files} | any()}
  def create(%User{} = reserver) do
    %{max_reserved: max_reserved, max_files: max_files} = user_upload_limits()

    Repo.one_shot(fn ->
      user_upload_counts = Upload.user_upload_counts(reserver.id)
      reserved_count = Map.get(user_upload_counts, :reserved, 0)
      total_count = Map.get(user_upload_counts, :uploaded, 0) + reserved_count

      cond do
        reserved_count >= max_reserved -> {:error, {:quota_reached, :max_reserved}}
        total_count >= max_files -> {:error, {:quota_reached, :max_files}}
        :else -> reserver |> Upload.new() |> Upload.put()
      end
    end)
  end

  @doc """
  Updates an `%Upload{}` previously reserved with `create/1` with the uploaded
  file.
  """
  @spec upload(Upload.t(), FileInfo.t(), Path.t()) ::
          {:ok, Upload.t()} | {:error, :too_large | {:quota_reached, :max_bytes} | File.posix()}
  def upload(%Upload{file: :reserved} = upload, %FileInfo{} = file_info, tmp_upload_path, repo_path \\ path()) do
    Repo.one_shot(fn ->
      with :ok <- validate_upload_size(upload.uploaded_by_id, file_info.byte_size),
           {:ok, %Upload{} = upload} <- upload |> Upload.put_file(file_info) |> Upload.put(),
           :ok <- copy_upload_if_no_exists(tmp_upload_path, upload_file_path(upload, repo_path)) do
        PubSub.broadcast(PS, PS.file_uploaded(upload.id), {:file_uploaded, upload})
        {:ok, upload}
      end
    end)
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

      Upload.user_total_uploaded_bytes(uploader_id) + upload_size > user_upload_limits().max_bytes ->
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

  def upload_file_path(%Upload{} = upload, repo_path \\ path()) do
    Path.join([
      parse_repo_path(repo_path),
      Base.encode64(upload.id.server_name),
      "#{upload.file.sha256}.#{upload.file.type}"
    ])
  end

  defp parse_repo_path(:default), do: Application.app_dir(:radio_beam)
  defp parse_repo_path(repo_path) when is_binary(repo_path), do: repo_path
end
