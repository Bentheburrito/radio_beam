defmodule RadioBeam.Database.Mnesia.Tables.Upload do
  @moduledoc false

  alias RadioBeam.ContentRepo

  require Record
  Record.defrecord(:upload, __MODULE__, id: nil, file: nil, created_at: nil, uploaded_by_id: nil)

  @type t() ::
          record(:upload,
            id: ContentRepo.MatrixContentURI.t(),
            file: ContentRepo.Upload.FileInfo.t(),
            created_at: DateTime.t(),
            uploaded_by_id: RadioBeam.User.id()
          )

  def opts, do: [attributes: upload() |> upload() |> Keyword.keys(), type: :set, index: [:uploaded_by_id]]
end
