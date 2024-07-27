defmodule RadioBeamWeb.Schemas.Filter do
  import RadioBeamWeb.Schemas, only: [user_id: 1, room_id: 1]

  alias Polyjuice.Util.Schema
  alias RadioBeam.Room.Timeline

  def filter do
    %{
      "account_data" => optional(event_filter()),
      "event_fields" => optional(Schema.array_of(:string)),
      "event_format" => [Schema.enum(["client", "federation"]), default: "client"],
      "presence" => optional(event_filter()),
      "room" => optional(room_filter())
    }
  end

  defp event_filter do
    %{
      "limit" => optional(&limit/1),
      "not_senders" => optional(Schema.array_of(&user_id/1)),
      "senders" => optional(Schema.array_of(&user_id/1)),
      "not_types" => optional(Schema.array_of(:string)),
      "types" => optional(Schema.array_of(:string))
    }
  end

  defp room_filter do
    %{
      "account_data" => optional(room_event_filter()),
      "ephemeral" => optional(room_event_filter()),
      "include_leave" => [:boolean, default: false],
      "not_rooms" => optional(Schema.array_of(&room_id/1)),
      "rooms" => optional(Schema.array_of(&room_id/1)),
      "state" => optional(state_filter()),
      "timeline" => optional(room_event_filter())
    }
  end

  defp room_event_filter(max_events \\ Timeline.max_events(:timeline)) do
    %{
      "contains_url" => optional(:boolean),
      "include_redundant_members" => [:boolean, default: false],
      "lazy_load_members" => [:boolean, default: false],
      "limit" => optional(&limit(&1, max_events)),
      "not_rooms" => optional(Schema.array_of(&room_id/1)),
      "not_senders" => optional(Schema.array_of(&user_id/1)),
      "not_types" => optional(Schema.array_of(:string)),
      "rooms" => optional(Schema.array_of(&room_id/1)),
      "senders" => optional(Schema.array_of(&user_id/1)),
      "types" => optional(Schema.array_of(:string)),
      "unread_thread_notifications" => [:boolean, default: false]
    }
  end

  # idk why these 2 identical schemas have distinct names in the spec
  defp state_filter, do: room_event_filter(Timeline.max_events(:state))

  def limit(value, max_events \\ Timeline.max_events(:timeline))

  def limit(value, max_events) when is_binary(value) do
    case Integer.parse(value) do
      {limit, _} -> limit(limit, max_events)
      :error -> {:error, :invalid}
    end
  end

  def limit(value, max_events) when is_integer(value), do: {:ok, min(max_events, max(1, value))}
  def limit(_value, _max_events), do: {:error, :invalid}

  defp optional(type), do: [type, :optional]
end
