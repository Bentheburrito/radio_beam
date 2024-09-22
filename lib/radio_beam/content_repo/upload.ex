defmodule RadioBeam.ContentRepo.Upload do
  use Memento.Table,
    attributes: ~w|id byte_size filename mime_type sha256 uploaded_by_id|a,
    index: [:uploaded_by_id],
    type: :set

  alias RadioBeam.User
  alias RadioBeam.ContentRepo.MatrixContentURI

  def new(%MatrixContentURI{} = mxc, mime_type, %User{} = uploaded_by, content, filename \\ "Uploaded File") do
    %__MODULE__{
      id: mxc,
      byte_size: IO.iodata_length(content),
      filename: filename,
      mime_type: mime_type,
      sha256: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower),
      uploaded_by_id: uploaded_by.id
    }
  end

  def get(%MatrixContentURI{} = mxc) do
    Memento.transaction(fn -> Memento.Query.read(__MODULE__, mxc) end)
  end

  def path_for(%__MODULE__{} = upload) do
    Path.join([upload.id.server_name, upload.sha256])
  end

  def all_user_upload_sizes_ms("@" <> _ = uploaded_by_id) do
    match_head = {__MODULE__, :_, :"$1", :_, :_, :_, uploaded_by_id}
    [{match_head, [], [:"$1"]}]
  end
end
