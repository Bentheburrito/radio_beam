defmodule RadioBeam.Database.Mnesia.Tables.DynamicOAuth2Client do
  @moduledoc false
  require Record
  Record.defrecord(:dynamic_oauth2_client, __MODULE__, id: nil, dynamic_oauth2_client: nil)

  @type t() ::
          record(:dynamic_oauth2_client,
            id: RadioBeam.User.Authentication.OAuth2.client_id(),
            dynamic_oauth2_client: RadioBeam.User.Authentication.OAuth2.Builtin.DynamicOAuth2Client.t()
          )

  def opts, do: [attributes: dynamic_oauth2_client() |> dynamic_oauth2_client() |> Keyword.keys(), type: :set]
end
