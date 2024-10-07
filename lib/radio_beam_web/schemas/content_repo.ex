defmodule RadioBeamWeb.Schemas.ContentRepo do
  @moduledoc false

  alias RadioBeam.ContentRepo
  alias RadioBeamWeb.Schemas
  alias Polyjuice.Util.Schema

  def download do
    %{
      "timeout_ms" => [&Schemas.as_integer/1, default: ContentRepo.max_wait_for_download_ms()],
      "server_name" => :string,
      "media_id" => :string
    }
  end

  def thumbnail do
    %{
      "animated" => [:boolean, default: true],
      "height" => &Schemas.as_integer/1,
      "width" => &Schemas.as_integer/1,
      "method" => Schema.enum(%{"scale" => :scale, "crop" => :crop}),
      "timeout_ms" => [&Schemas.as_integer/1, default: ContentRepo.max_wait_for_download_ms()],
      "server_name" => :string,
      "media_id" => :string
    }
  end
end
