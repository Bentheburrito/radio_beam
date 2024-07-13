defmodule RadioBeamWeb.Schemas.Sync do
  alias Polyjuice.Util.Schema
  alias RadioBeamWeb.Schemas.Filter

  def sync do
    %{
      "filter" => optional(Schema.any_of([&filter_by_id/1, Filter.filter()])),
      "full_state" => [:boolean, default: false],
      "set_presence" => [Schema.enum(presence()), default: :online],
      "since" => optional(:string),
      "timeout" => [:integer, default: 0]
    }
  end

  defp filter_by_id("{" <> _), do: {:error, :invalid}

  defp filter_by_id(filter_id) do
    case RadioBeam.Room.Timeline.Filter.get(filter_id) do
      {:ok, %{definition: definition}} -> {:ok, definition}
      {:error, _} -> {:error, :invalid}
    end
  end

  defp presence, do: %{"offline" => :offline, "unavailable" => :unavailable, "online" => :online}

  defp optional(type), do: [type, :optional]
end