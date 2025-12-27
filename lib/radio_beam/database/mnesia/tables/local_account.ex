defmodule RadioBeam.Database.Mnesia.Tables.LocalAccount do
  @moduledoc false

  require Record
  Record.defrecord(:local_account, __MODULE__, id: nil, local_account: nil)

  @type t() :: record(:local_account, id: RadioBeam.User.id(), local_account: RadioBeam.User.LocalAccount.t())

  def opts, do: [attributes: local_account() |> local_account() |> Keyword.keys(), type: :set]
end
