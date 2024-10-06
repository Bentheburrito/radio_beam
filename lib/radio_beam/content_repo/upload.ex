defmodule RadioBeam.ContentRepo.Upload do
  @moduledoc """
  An `%Upload{}` represents a user-uploaded file on disk, including metadata
  such as its size and who it was uploaded by.
  """
  use Memento.Table,
    attributes: ~w|id file inserted_at uploaded_by_id|a,
    index: [:uploaded_by_id],
    type: :set

  alias RadioBeam.User
  alias RadioBeam.ContentRepo.MatrixContentURI
  alias RadioBeam.ContentRepo.Upload.FileInfo

  @typedoc """
  The state of the upload in the content repository.
  - `:unreserved` - the struct has not been checked against the repository yet;
    it's unknown if its `:id` has already been taken by another upload.
  - `:reserved` - the upload's `:id` has been reserved in the content
    repository, and is ready for the file to be uploaded by the client.
  - `FileInfo.t()` - A `FileInfo` struct, containing metadata about the
    uploaded file.
  """
  @type file() :: :unreserved | :reserved | FileInfo.t()

  @type t() :: %__MODULE__{
          id: MatrixContentURI.t(),
          file: file(),
          inserted_at: DateTime.t(),
          uploaded_by_id: User.id()
        }

  def new(%User{} = uploaded_by, %MatrixContentURI{} = mxc \\ MatrixContentURI.new!()) do
    %__MODULE__{
      id: mxc,
      file: nil,
      inserted_at: DateTime.utc_now(),
      uploaded_by_id: uploaded_by.id
    }
  end

  def put_file(%__MODULE__{file: file} = upload, %FileInfo{} = file_info) when file in [nil, :reserved] do
    %__MODULE__{upload | file: file_info}
  end

  def put(%__MODULE__{} = upload), do: Memento.transaction(fn -> putT(upload) end)

  def putT(%__MODULE__{file: nil} = upload), do: Memento.Query.write(%__MODULE__{upload | file: :reserved})
  def putT(%__MODULE__{} = upload), do: Memento.Query.write(upload)

  def get(%MatrixContentURI{} = mxc) do
    case Memento.transaction(fn -> getT(mxc) end) do
      {:ok, nil} -> {:error, :not_found}
      result -> result
    end
  end

  def getT(%MatrixContentURI{} = mxc, opts \\ []), do: Memento.Query.read(__MODULE__, mxc, opts)

  def user_total_uploaded_bytesT("@" <> _ = uploaded_by_id) do
    match_head = {__MODULE__, :_, :"$1", :_, uploaded_by_id}
    match_spec = [{match_head, [{:is_map, :"$1"}], [:"$1"]}]

    __MODULE__
    |> Memento.Query.select_raw(match_spec, coerce: false)
    |> Stream.map(& &1.byte_size)
    |> Enum.sum()
  end

  def user_upload_countsT("@" <> _ = uploaded_by_id) do
    match_head = {__MODULE__, :_, :"$1", :_, uploaded_by_id}
    match_spec = [{match_head, [], [:"$1"]}]

    __MODULE__
    |> Memento.Query.select_raw(match_spec, coerce: false)
    |> Enum.reduce(%{}, fn
      :reserved, acc -> Map.update(acc, :reserved, 1, &(&1 + 1))
      %FileInfo{}, acc -> Map.update(acc, :uploaded, 1, &(&1 + 1))
    end)
  end
end
