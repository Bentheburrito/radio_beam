defmodule RadioBeamWeb.Schemas.ContentRepo do
  @moduledoc false

  alias RadioBeamWeb.Schemas
  alias Polyjuice.Util.Schema

  def thumbnail do
    %{
      "animated" => [:boolean, default: true],
      "height" => &Schemas.as_integer/1,
      "width" => &Schemas.as_integer/1,
      "method" => Schema.enum(%{"scale" => :scale, "crop" => :crop}),
      "timeout_ms" => [&Schemas.as_integer/1, default: :timer.seconds(20)],
      "server_name" => :string,
      "media_id" => :string
    }
  end
end
