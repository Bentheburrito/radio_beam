defmodule RadioBeam.Database.Mnesia.Tables.UserClientConfig do
  @moduledoc false

  require Record
  Record.defrecord(:user_client_config, __MODULE__, user_id: nil, client_config: nil)

  @type t() :: record(:user_client_config, user_id: RadioBeam.User.id(), client_config: RadioBeam.User.ClientConfig.t())

  def opts, do: [attributes: user_client_config() |> user_client_config() |> Keyword.keys(), type: :set]
end
