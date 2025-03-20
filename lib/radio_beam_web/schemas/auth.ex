defmodule RadioBeamWeb.Schemas.Auth do
  @moduledoc false

  alias RadioBeamWeb.Schemas
  alias Polyjuice.Util.Schema

  def refresh, do: %{"refresh_token" => :string}

  def register do
    %{
      "device_id" => [:string, default: RadioBeam.User.Device.generate_id()],
      "inhibit_login" => [:boolean, default: false],
      "initial_device_display_name" => [:string, default: RadioBeam.User.Device.default_device_name()],
      "password" => :string,
      "username" => &Schema.user_localpart/1
    }
  end

  def login do
    # TOIMPL: token login, 3rd party login
    %{
      "device_id" => [:string, default: RadioBeam.User.Device.generate_id()],
      "identifier" => %{
        "type" => Schema.enum(["m.id.user"]),
        "user" => Schema.any_of([&Schema.user_localpart/1, &Schemas.user_id/1])
      },
      "initial_device_display_name" => [:string, default: RadioBeam.User.Device.default_device_name()],
      "password" => :string,
      "type" => Schema.enum(["m.login.password"])
    }
  end
end
