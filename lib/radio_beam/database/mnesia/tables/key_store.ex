defmodule RadioBeam.Database.Mnesia.Tables.KeyStore do
  @moduledoc false

  require Record
  Record.defrecord(:key_store, __MODULE__, user_id: nil, key_store: nil)

  @type t() :: record(:key_store, user_id: RadioBeam.User.id(), key_store: RadioBeam.User.KeyStore.t())

  def opts, do: [attributes: key_store() |> key_store() |> Keyword.keys(), type: :set]
end
