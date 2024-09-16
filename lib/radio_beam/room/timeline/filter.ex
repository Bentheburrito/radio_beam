defmodule RadioBeam.Room.Timeline.Filter do
  @moduledoc """
  A client-defined filter describing what kinds of events to include in an
  event timeline.
  """
  @types [id: :string, user_id: :string, definition: :map]
  @attrs Keyword.keys(@types)

  use Memento.Table,
    attributes: @attrs,
    type: :set

  import Kernel, except: [apply: 2]

  alias RadioBeam.Room.Timeline

  def put(user_id, definition) do
    id = 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64()

    fn -> Memento.Query.write(%__MODULE__{id: id, user_id: user_id, definition: definition}) end
    |> Memento.transaction()
    |> case do
      {:ok, _} -> {:ok, id}
      error -> error
    end
  end

  def get(filter_id) do
    Memento.transaction(fn -> Memento.Query.read(__MODULE__, filter_id) end)
  end

  @doc """
  Strips the given event of any fields not in `event_fields`. Supports 
  dot-separated nested field names. If `event_fields` is `nil`, returns the
  event unmodified.
    
    iex> event = %{"state_key" => "@test:localhost", "content" => %{"my_key" => 123, "other_key" => 321}}
    iex> RadioBeam.Room.Timeline.Filter.take_fields(event, ~w|state_key content.my_key|)
    %{"state_key" => "@test:localhost", "content" => %{"my_key" => 123}}
  """
  def take_fields(%{} = event, nil), do: event

  def take_fields(%{} = event, event_fields) do
    event_fields
    |> Stream.map(&String.split(&1, "."))
    |> Enum.reduce(%{}, fn path, new_event ->
      RadioBeam.put_nested(new_event, path, get_in(event, path))
    end)
  end

  @doc """
  Parses a raw filter definition into a nicer-to-use map (atom keys, all keys
  are guaranteed to be present with at least default values, the weird "rooms"
  and "not_rooms" and similar fields are parsed into {:allowlist, allowlist} 
  and {:denylist, denylist} tuples.

  TOIMPL include_redundant_members, lazy_load_members, unread_thread_notifications
  """
  def parse(%__MODULE__{definition: definition}), do: parse(definition)

  def parse(definition) when is_map(definition) do
    room_def = Map.get(definition, "room", %{})
    timeline = room_def |> Map.get("timeline", %{}) |> parse_event_filter(:timeline)
    state = room_def |> Map.get("state", %{}) |> parse_event_filter(:state)
    format = Map.get(definition, "event_format", "client")
    format = if format in ["client", "federation"], do: format, else: "client"
    fields = Map.get(definition, "event_fields")

    global_rooms = merge_filter_list(room_def, "rooms", "not_rooms")

    %{
      timeline: timeline,
      state: state,
      format: format,
      fields: fields,
      rooms: global_rooms,
      include_leave?: Map.get(room_def, "include_leave", false) == true
    }
  end

  defp parse_event_filter(filter, event_kind) do
    max_events = Timeline.max_events(event_kind)

    for allowlist_key <- ["senders", "types", "rooms"], into: %{} do
      denylist_key = "not_#{allowlist_key}"

      parsed_filter = merge_filter_list(filter, allowlist_key, denylist_key)

      {String.to_existing_atom(allowlist_key), parsed_filter}
    end
    |> Map.merge(%{
      contains_url: Map.get(filter, "contains_url", :none),
      memberships: parse_memberships(filter),
      limit: filter |> Map.get("limit", max_events) |> min(max_events)
    })
  end

  defp merge_filter_list(filter, allowlist_key, denylist_key) do
    case filter do
      %{^allowlist_key => allowlist} ->
        denylist = Map.get(filter, denylist_key, [])

        {:allowlist,
         allowlist
         |> MapSet.new()
         |> MapSet.difference(MapSet.new(denylist))
         |> MapSet.to_list()}

      %{^denylist_key => denylist} ->
        {:denylist, denylist}

      _else ->
        :none
    end
  end

  defp parse_memberships(filter) do
    lazy? = Map.get(filter, "lazy_load_members", false)
    redundant? = Map.get(filter, "include_redundant_members", false)

    cond do
      lazy? and redundant? -> :lazy_redundant
      lazy? -> :lazy
      :else -> :all
    end
  end
end
