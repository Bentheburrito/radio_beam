defmodule RadioBeamWeb.Schemas.Sync do
  alias RadioBeam.Room.Timeline
  alias Polyjuice.Util.Schema
  alias RadioBeamWeb.Schemas.Filter
  alias RadioBeamWeb.Schemas

  def sync do
    %{
      "filter" => optional(Schema.any_of([&filter_by_id/1, &Filter.json_filter/1, Filter.filter()])),
      "full_state" => [:boolean, default: false],
      "set_presence" => [Schema.enum(presence()), default: :online],
      "since" => optional(:string),
      "timeout" => [&Schemas.as_integer/1, default: 0]
    }
  end

  def get_messages do
    %{
      "dir" => Schema.enum(%{"f" => :forward, "b" => :backward}, &String.downcase/1),
      "filter" => optional(Schema.any_of([&filter_by_id/1, Filter.filter()])),
      "from" => optional(&from_token/1),
      "limit" => [&Filter.limit/1, default: Timeline.max_events(:timeline)],
      "to" => optional(:string)
    }
  end

  defp from_token("first"), do: {:ok, :first}
  defp from_token("last"), do: {:ok, :last}
  defp from_token(from), do: {:ok, from}

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
