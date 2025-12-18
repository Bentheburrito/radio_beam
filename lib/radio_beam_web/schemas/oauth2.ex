defmodule RadioBeamWeb.Schemas.OAuth2 do
  @moduledoc false

  alias Polyjuice.Util.Schema

  def get_token do
    Schema.any_of([
      %{
        "grant_type" => Schema.enum(RadioBeam.OAuth2.metadata().grant_types_supported),
        "code" => :string,
        "redirect_uri" => :string,
        "client_id" => :string,
        "code_verifier" => :string
      },
      %{
        "grant_type" => Schema.enum(RadioBeam.OAuth2.metadata().grant_types_supported),
        "refresh_token" => :string,
        "client_id" => :string
      }
    ])
  end
end
