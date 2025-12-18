defmodule RadioBeam.OAuth2.Builtin.DynamicOAuth2Client do
  defstruct [
    :client_id,
    :application_type,
    :client_name,
    :client_uri,
    :grant_types,
    :logo_uri,
    :policy_uri,
    :redirect_uris,
    :response_types,
    :token_endpoint_auth_method,
    :tos_uri
  ]

  def new!(init_params) do
    init_params_binary = :erlang.term_to_binary(init_params)
    client_id = :sha256 |> :crypto.hash(init_params_binary) |> Base.encode16(case: :lower)

    struct!(__MODULE__, Map.put(init_params, :client_id, client_id))
  end

  defimpl JSON.Encoder do
    def encode(client_metadata, encoder) do
      client_metadata
      |> Map.from_struct()
      |> JSON.Encoder.Map.encode(encoder)
    end
  end
end
