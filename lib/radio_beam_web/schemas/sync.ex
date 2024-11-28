defmodule RadioBeamWeb.Schemas.Sync do
  @moduledoc false

  alias RadioBeam.Room.EventGraph.PaginationToken
  alias RadioBeam.Room.Timeline
  alias Polyjuice.Util.Schema
  alias RadioBeamWeb.Schemas.Filter
  alias RadioBeamWeb.Schemas

  def sync do
    %{
      "filter" => optional(Schema.any_of([&filter_by_id/1, &Filter.json_filter/1, Filter.filter()])),
      "full_state" => [:boolean, default: false],
      "set_presence" => [Schema.enum(presence()), default: :online],
      "since" => optional(&pagination_token/1),
      "timeout" => [&Schemas.as_integer/1, default: 0]
    }
  end

  def get_messages do
    %{
      "dir" => Schema.enum(%{"f" => :forward, "b" => :backward}, &String.downcase/1),
      "filter" => optional(Schema.any_of([&filter_by_id/1, Filter.filter()])),
      "from" => optional(&pagination_token/1),
      "limit" => [&Filter.limit/1, default: Timeline.max_events(:timeline)],
      "to" => optional(&pagination_token/1)
    }
  end

  defp pagination_token(token), do: PaginationToken.parse(token)

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
