defmodule RadioBeam.Database.Mnesia.Tables.Keys do
  @moduledoc false

  require Record
  Record.defrecord(:keys, __MODULE__, user_id: nil, keys: nil)

  @type t() :: record(:keys, user_id: RadioBeam.User.id(), keys: RadioBeam.User.Keys.t())

  def opts, do: [attributes: keys() |> keys() |> Keyword.keys(), type: :set]
end
