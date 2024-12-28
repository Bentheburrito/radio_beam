defmodule RadioBeam.Room.Timeline.Core do
  @moduledoc """
  Functional core for syncing with clients and reading the event graph.
  """

  alias RadioBeam.PDU
  alias RadioBeam.Room
  alias RadioBeam.Room.Timeline
  alias RadioBeam.Room.Timeline.Filter

  def sync_timeline(timeline, state_delta_pdus, user_id, config) do
    tl_start_event = List.first(timeline.events)

    if is_nil(tl_start_event) and not config.full_state? do
      :no_update
    else
      get_senders = fn -> get_tl_senders(timeline.events, user_id) end
      state_delta = filter_state_delta(state_delta_pdus, get_senders, config)

      cond do
        Enum.empty?(state_delta) and
            (Enum.empty?(timeline.events) or not allowed_room?(config.room.id, config.filter.timeline.rooms)) ->
          :no_update

        :else ->
          %{
            state: %{events: state_delta},
            timeline: %Timeline{timeline | events: format(timeline.events, config.filter, config.room.version)}
          }
      end
    end
  end

  def format(timeline, filter, room_version) do
    format = String.to_existing_atom(filter.format)
    Enum.map(timeline, &(&1 |> PDU.to_event(room_version, :atoms, format) |> Filter.take_fields(filter.fields)))
  end

  def all_sender_ids(%{timeline: %Timeline{} = tl}, opts), do: all_sender_ids(tl, opts)
  def all_sender_ids(%Timeline{} = timeline, opts), do: all_sender_ids(timeline.events, opts)

  def all_sender_ids(events, opts) do
    except = Keyword.get(opts, :except, [])
    events |> Stream.map(& &1.sender) |> Stream.reject(&(&1 in except)) |> Stream.uniq() |> Enum.to_list()
  end

  def handle_room_message(msg, config_map, user_id) do
    case msg do
      {:room_event, room_id, pdu} ->
        sync_config = Map.fetch!(config_map, room_id)

        if passes_filter?(sync_config.filter.timeline, pdu) and filter_authz([pdu], room_id, user_id, "join") do
          case sync_timeline(Timeline.complete([pdu]), [], user_id, sync_config) do
            :no_update -> :keep_waiting
            timeline -> {%{join: %{sync_config.room.id => timeline}}, [pdu]}
          end
        else
          :keep_waiting
        end

      {:room_stripped_state, _room_id, _pdu} ->
        # see TODO in Timeline.sync_one
        :keep_waiting

      {:room_invite, room, pdu} ->
        event = PDU.to_event(pdu, room.version, :strings)
        room = Room.Core.update_state(room, event)
        {%{invite: %{room.id => %{invite_state: %{events: Room.stripped_state(room, user_id)}}}}, [pdu]}
    end
  end

  def get_state_delta_ids(_, %{state_events: tl_start_state_ids}, true), do: tl_start_state_ids

  def get_state_delta_ids(%{state_events: last_sync_state_ids} = last_sync_pdu, nil, true) do
    if is_nil(last_sync_pdu.state_key) do
      last_sync_state_ids
    else
      [last_sync_pdu.event_id | last_sync_state_ids]
    end
  end

  def get_state_delta_ids(
        %{state_events: last_sync_state_ids} = last_sync_pdu,
        %{state_events: tl_start_state_ids},
        false
      ) do
    last_sync_state_ids =
      if is_nil(last_sync_pdu.state_key) do
        last_sync_state_ids
      else
        [last_sync_pdu.event_id | last_sync_state_ids]
      end

    tl_start_state_ids
    |> MapSet.new()
    |> MapSet.difference(MapSet.new(last_sync_state_ids))
    |> MapSet.to_list()
  end

  def get_state_delta_ids(nil, %{state_events: tl_start_state_ids}, false), do: tl_start_state_ids

  def get_state_delta_ids(_, _, _), do: []

  defp filter_state_delta(state_delta_pdus, get_senders, config) do
    if allowed_room?(config.room.id, config.filter.state.rooms) do
      senders = if config.filter.state.memberships == :all, do: [], else: get_senders.()

      state_delta_pdus
      |> Stream.filter(&include_state_event?(&1, config.filter.state, senders, config.known_memberships))
      |> format(config.filter, config.room.version)
    else
      []
    end
  end

  defp include_state_event?(%PDU{} = pdu, filter, senders, known_memberships) do
    (pdu.type != "m.room.member" or include_membership_event?(pdu, filter, senders, known_memberships)) and
      passes_filter?(filter, pdu)
  end

  defp include_state_event?(event, filter, senders, known_memberships) do
    (event["type"] != "m.room.member" or include_membership_event?(event, filter, senders, known_memberships)) and
      passes_filter?(filter, event)
  end

  defp include_membership_event?(%PDU{} = pdu, filter, senders, known_memberships) do
    case filter.memberships do
      :lazy -> pdu.state_key not in known_memberships and pdu.state_key in senders
      :lazy_redundant -> pdu.state_key in senders
      :all -> true
    end
  end

  defp include_membership_event?(event, filter, senders, known_memberships) do
    case filter.memberships do
      :lazy -> event["state_key"] not in known_memberships and event["state_key"] in senders
      :lazy_redundant -> event["state_key"] in senders
      :all -> true
    end
  end

  defp get_tl_senders(events, user_id), do: events |> MapSet.new(& &1.sender) |> MapSet.put(user_id)

  defp allowed_room?(room_id, {:allowlist, allowlist}), do: room_id in allowlist
  defp allowed_room?(room_id, {:denylist, denylist}), do: room_id not in denylist
  defp allowed_room?(_room_id, :none), do: true

  def filter_authz(pdus, user_id, user_membership_at_first_pdu, user_joined_later?) do
    {_, pdus} =
      Enum.reduce(pdus, {user_membership_at_first_pdu, []}, fn pdu, {membership, visible_pdus} ->
        visible_pdus =
          if visible?(pdu, user_id, membership, user_joined_later?, pdu.current_visibility) do
            [pdu | visible_pdus]
          else
            visible_pdus
          end

        {(pdu.state_key == user_id && pdu.content["membership"]) || membership, visible_pdus}
      end)

    pdus
  end

  def passes_filter?(filter, %{content: content, type: type, sender: sender}),
    do: filter_url(filter, content) and filter_type(filter, type) and filter_sender(filter, sender)

  def passes_filter?(filter, %{"content" => content, "type" => type, "sender" => sender}),
    do: filter_url(filter, content) and filter_type(filter, type) and filter_sender(filter, sender)

  defp filter_url(%{contains_url: :none}, _), do: true
  defp filter_url(%{contains_url: true}, %{"url" => _}), do: true
  defp filter_url(%{contains_url: false}, content) when not is_map_key(content, "url"), do: true
  defp filter_url(_, _), do: false

  # TOIMPL: support for * wildcards in types
  defp filter_type(%{types: {:allowlist, allowlist}}, type), do: type in allowlist
  defp filter_type(%{types: {:denylist, denylist}}, type), do: type not in denylist
  defp filter_type(%{types: :none}, _), do: true

  defp filter_sender(%{senders: {:allowlist, allowlist}}, sender), do: sender in allowlist
  defp filter_sender(%{senders: {:denylist, denylist}}, sender), do: sender not in denylist
  defp filter_sender(%{senders: :none}, _), do: true

  # For m.room.history_visibility events themselves, the user should be
  # allowed to see the event if the history_visibility before or after the
  # event would allow them to see it
  def visible?(%PDU{type: "m.room.history_visibility"} = pdu, _user_id, membership, joined_later?, history_vis) do
    visible?(membership, joined_later?, history_vis) or
      visible?(membership, joined_later?, pdu.content["history_visibility"])
  end

  # Likewise, for the user’s own m.room.member events, the user should be
  # allowed to see the event if their membership before or after the event
  # would allow them to see it.
  def visible?(%PDU{type: "m.room.member", state_key: user_id} = pdu, user_id, membership, joined_later?, history_vis) do
    visible?(membership, joined_later?, history_vis) or visible?(pdu.content["membership"], joined_later?, history_vis)
  end

  def visible?(_pdu, _user_id, membership, joined_later?, history_vis),
    do: visible?(membership, joined_later?, history_vis)

  defp visible?(_membership_at_event, _user_joined_later?, "world_readable"), do: true
  defp visible?("join", _user_joined_later?, _history_visibility), do: true
  defp visible?(_membership_at_event, user_joined_later?, "shared"), do: user_joined_later?
  defp visible?("invite", _user_joined_later?, "invited"), do: true
  defp visible?(_membership_at_event, _user_joined_later?, _history_visibility), do: false
end
