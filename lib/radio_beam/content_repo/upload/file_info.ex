defmodule RadioBeam.ContentRepo.Upload.FileInfo do
  @moduledoc """
  Metadata for the file associated with an `%Upload{}`.
  """
  @attrs ~w|byte_size filename sha256 type|a
  @enforce_keys @attrs
  defstruct @attrs

  @type t() :: %__MODULE__{
          byte_size: non_neg_integer(),
          filename: String.t(),
          sha256: String.t(),
          type: String.t()
        }

  def new(type, size, sha256, filename) do
    %__MODULE__{
      byte_size: size,
      filename: filename,
      sha256: sha256,
      type: type
    }
  end
end
