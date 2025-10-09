defmodule RadioBeam.User.EventFilter do
  @moduledoc """
  A client-defined filter describing what kinds of events to include in
  responses to certain API calls, and how to format those events.
  """
  import Kernel, except: [apply: 2]

  @types [
    id: :string,
    fields: :map,
    format: :map,
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
  def new(%{} = definition) do
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
      limit: filter |> Map.get("limit", max_events) |> min(max_events) |> max(1)
    })
  end

  defp merge_filter_list(filter, allowlist_key, denylist_key) do
    case filter do
      %{^allowlist_key => []} ->
        :none

      %{^allowlist_key => allowlist} ->
        denylist = Map.get(filter, denylist_key, [])

        {:allowlist,
         allowlist
         |> MapSet.new()
         |> MapSet.difference(MapSet.new(denylist))
         |> MapSet.to_list()}

      %{^denylist_key => []} ->
        :none

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

  def allow_timeline_event?(filter, event), do: apply(filter.timeline, event)

  def allow_state_event?(filter, event, senders, known_memberships) do
    apply(filter.state, event) and apply_membership_filter(filter.state, event, senders, known_memberships)
  end

  defp apply(filter, %{content: content, type: type, sender: sender}) do
    filter_url(filter, content) and filter_type(filter, type) and filter_sender(filter, sender)
  end

  defp apply_membership_filter(filter, %{type: "m.room.member"} = event, senders, known_memberships) do
    case filter.memberships do
      :lazy -> event.state_key not in known_memberships and event.state_key in senders
      :lazy_redundant -> event.state_key in senders
      :all -> true
    end
  end

  defp apply_membership_filter(_filter, _event, _senders, _known_memberships), do: true

  defp filter_url(%{contains_url: :none}, _), do: true
  defp filter_url(%{contains_url: true}, %{"url" => _}), do: true
  defp filter_url(%{contains_url: false}, content) when not is_map_key(content, "url"), do: true
  defp filter_url(_, _), do: false

  # TOIMPL: support for * wildcards in types
  defp filter_type(%{types: types}, type), do: allow_listed?(type, types)

  defp filter_sender(%{senders: senders}, sender), do: allow_listed?(sender, senders)

  @doc "whether to include relevant state events/deltas"
  def allow_state_in_room?(filter, room_id), do: allow_listed?(room_id, filter.state.rooms)
  @doc "whether to include timeline events"
  def allow_timeline_in_room?(filter, room_id), do: allow_listed?(room_id, filter.timeline.rooms)

  defp allow_listed?(item, {:allowlist, allowlist}), do: item in allowlist
  defp allow_listed?(item, {:denylist, denylist}), do: item not in denylist
  defp allow_listed?(_item, :none), do: true
end
