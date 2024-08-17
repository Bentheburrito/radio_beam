defmodule RadioBeamWeb.Schemas.Auth do
  @moduledoc false

  alias Polyjuice.Util.Schema

  def refresh, do: %{"refresh_token" => :string}

  def register, do: %{"username" => &Schema.user_localpart/1, "password" => :string}
end
