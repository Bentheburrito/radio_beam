defmodule RadioBeam.ContentRepo.Upload do
  use Memento.Table,
    attributes: ~w|id byte_size filename inserted_at mime_type sha256 uploaded_by_id|a,
    index: [:uploaded_by_id],
    type: :set

  alias RadioBeam.User
  alias RadioBeam.ContentRepo.MatrixContentURI

  def new(%MatrixContentURI{} = mxc, mime_type, %User{} = uploaded_by, content, filename \\ "Uploaded File") do
    %__MODULE__{
      id: mxc,
      byte_size: IO.iodata_length(content),
      filename: filename,
      inserted_at: DateTime.utc_now(),
      mime_type: mime_type,
      sha256: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower),
      uploaded_by_id: uploaded_by.id
    }
  end

  def new_pending(%MatrixContentURI{} = mxc, %User{} = reserved_by) do
    %__MODULE__{
      id: mxc,
      byte_size: :pending,
      filename: :pending,
      inserted_at: DateTime.utc_now(),
      mime_type: :pending,
      sha256: :pending,
      uploaded_by_id: reserved_by.id
    }
  end

  def get(%MatrixContentURI{} = mxc) do
    fn -> getT(mxc) end
    |> Memento.transaction()
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %__MODULE__{} = upload} -> {:ok, upload}
      error -> error
    end
  end

  def getT(%MatrixContentURI{} = mxc), do: Memento.Query.read(__MODULE__, mxc)

  def path_for(%__MODULE__{} = upload) do
    Path.join([upload.id.server_name, upload.sha256])
  end

  def all_user_upload_sizes_ms("@" <> _ = uploaded_by_id) do
    match_head = {__MODULE__, :"$2", :"$1", :_, :_, :_, :_, uploaded_by_id}
    [{match_head, [{:"=/=", :"$2", :pending}], [:"$1"]}]
  end

  def get_num_pending_uploadsT("@" <> _ = uploaded_by_id) do
    match_head = {__MODULE__, :_, :"$1", :"$1", :_, :"$1", :"$1", uploaded_by_id}
    match_spec = [{match_head, [{:"=:=", :"$1", :pending}], [:"$1"]}]

    __MODULE__
    |> Memento.Query.select_raw(match_spec, coerce: false)
    |> Enum.count()
  end
end
