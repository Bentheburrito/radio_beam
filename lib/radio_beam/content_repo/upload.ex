defmodule RadioBeam.ContentRepo.Upload do
  @moduledoc """
  An `%Upload{}` represents a user-uploaded file on disk, including metadata
  such as its size and who it was uploaded by.
  """
  defstruct ~w|id file created_at uploaded_by_id|a

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
          created_at: DateTime.t(),
          uploaded_by_id: User.id()
        }

  def new("@" <> _ = uploaded_by_id, %MatrixContentURI{} = mxc \\ MatrixContentURI.new!()) do
    %__MODULE__{
      id: mxc,
      file: :reserved,
      created_at: DateTime.utc_now(),
      uploaded_by_id: uploaded_by_id
    }
  end

  def put_file(%__MODULE__{file: file} = upload, %FileInfo{} = file_info) when file == :reserved do
    %__MODULE__{upload | file: file_info}
  end
end
