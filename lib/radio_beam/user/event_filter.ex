defmodule RadioBeam.User.EventFilter do
  @moduledoc """
  A client-defined filter describing what kinds of events to include in
  responses to certain API calls, and how to format those events.
  """
  @types [
    fields: :map,
    format: :map,
    id: :string,
    include_leave?: :boolean,
    raw_definition: :map,
    rooms: :map,
    state: :map,
    timeline: :map
  ]
  @attrs Keyword.keys(@types)
  @enforce_keys @attrs
  defstruct @attrs

  @type t() :: %__MODULE__{}
  @type id() :: Ecto.UUID.t()

  @doc """
  Strips the given event of any fields not in `event_fields`. Supports 
  dot-separated nested field names. If `event_fields` is `nil`, returns the
  event unmodified.
    
    iex> event = %{"state_key" => "@test:localhost", "content" => %{"my_key" => 123, "other_key" => 321}}
    iex> RadioBeam.User.EventFilter.take_fields(event, ~w|state_key content.my_key|)
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
  Creates a new event filter, parsing the given filter definition as defined in
  the C-S spec. 

  TOIMPL unread_thread_notifications
  """
  def new(%{} = definition) when is_map(definition) do
    room_def = Map.get(definition, "room", %{})
    timeline = room_def |> Map.get("timeline", %{}) |> parse_event_filter(RadioBeam.max_timeline_events())
    state = room_def |> Map.get("state", %{}) |> parse_event_filter(RadioBeam.max_state_events())
    format = Map.get(definition, "event_format", "client")
    format = if format in ["client", "federation"], do: format, else: "client"
    fields = Map.get(definition, "event_fields")

    global_rooms = merge_filter_list(room_def, "rooms", "not_rooms")

    %__MODULE__{
      fields: fields,
      format: format,
      id: Ecto.UUID.generate(),
      include_leave?: Map.get(room_def, "include_leave", false) == true,
      raw_definition: definition,
      rooms: global_rooms,
      state: state,
      timeline: timeline
    }
  end

  defp parse_event_filter(filter, max_events) do
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
