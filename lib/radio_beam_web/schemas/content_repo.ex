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
      "animated" => [&animated?/1, default: true],
      "height" => &Schemas.as_integer/1,
      "width" => &Schemas.as_integer/1,
      "method" => Schema.enum(%{"scale" => :scale, "crop" => :crop}),
      "timeout_ms" => [&Schemas.as_integer/1, default: ContentRepo.max_wait_for_download_ms()],
      "server_name" => :string,
      "media_id" => :string
    }
  end

  defp animated?(value) do
    case value do
      bool when is_boolean(bool) -> {:ok, bool}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _else -> {:error, :not_a_boolean}
    end
  end
end
