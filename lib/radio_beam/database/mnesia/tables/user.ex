defmodule RadioBeam.Database.Mnesia.Tables.User do
  @moduledoc false

  require Record
  Record.defrecord(:user, __MODULE__, id: nil, user: nil)

  @type t() :: record(:user, id: RadioBeam.User.id(), user: RadioBeam.User.t())

  def opts, do: [attributes: user() |> user() |> Keyword.keys(), type: :set]
end
