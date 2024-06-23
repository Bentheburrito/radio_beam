defmodule RadioBeamWeb.Schemas.Sync do
  alias Polyjuice.Util.Schema

  def sync do
    %{
      "filter" => optional(Schema.any_of([:string, filter()])),
      "full_state" => [:boolean, default: false],
      "set_presence" => [Schema.enum(presence()), default: :online],
      "since" => optional(:string),
      "timeout" => [:integer, default: 0]
    }
  end

  # TOIMPL
  def filter do
    %{}
  end

  defp presence, do: %{"offline" => :offline, "unavailable" => :unavailable, "online" => :online}

  defp optional(type), do: [type, :optional]
end
