defmodule RadioBeam.Repo.Tables.DynamicOAuth2Client do
  @moduledoc false
  use Memento.Table,
    attributes: [:client_id, :client_metadata],
    type: :set

  def dump!(%RadioBeam.User.Authentication.OAuth2.Builtin.DynamicOAuth2Client{client_id: client_id} = client_metadata),
    do: %__MODULE__{client_id: client_id, client_metadata: client_metadata}

  def load!(%__MODULE__{client_metadata: client_metadata}), do: client_metadata
end
