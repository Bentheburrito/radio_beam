defmodule RadioBeam.Room.Timeline.Filter do
  @moduledoc """
  notes reading "6.1. Lazy-loading room members":
  - lazy_load_members should be pretty straight forward, although annoying to
    have to do extra processing on pdu.prev_state...
  - the whole "the server MAY assume that clients will remember membership 
    events they have already been sent" makes sense, though still sounds messy
    and will be impl'd alongside `include_redundant_members` much later. 
    However, an idea of an impl might be:
    - bring in Cachex, add a `RoomMemberCache` to sup tree, which maps access
      tokens to {room_id, user_id} pairs, such that an entry implies the 
      syncing user/device has already been sent the membership event for that 
      user. A shortish TLL for each entry
    - /sync and other endpoints put entries in the cache as they reply with 
      membership events.
    - we'll need some other process to listen to a PubSub topic of membership
      updates, and remove cache entries as appropriate
  - 
  """
  @types [id: :string, user_id: :string, definition: :map]
  @attrs Keyword.keys(@types)

  use Memento.Table,
    attributes: @attrs,
    type: :set

  import Kernel, except: [apply: 2]

  alias RadioBeam.PDU

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
  Applies the given filter to a list of room IDs
  """
  def apply_rooms(%__MODULE__{} = filter, room_ids), do: apply_rooms(filter.definition, room_ids)
  def apply_rooms(_filter, []), do: []

  def apply_rooms(%{} = filter, ["!" <> _ | _] = room_ids) do
    case filter["room"] do
      %{"not_rooms" => excluded_rooms, "rooms" => included_rooms} ->
        room_ids |> Stream.reject(&(&1 in excluded_rooms)) |> Enum.filter(&(&1 in included_rooms))

      %{"not_rooms" => excluded_rooms} ->
        Enum.reject(room_ids, &(&1 in excluded_rooms))

      %{"rooms" => included_rooms} ->
        Enum.filter(room_ids, &(&1 in included_rooms))

      _ ->
        room_ids
    end
  end

  @doc """
  Applies the given filter to the event, EXCEPT for the "limit", "rooms", and 
  "not_rooms" fields. Those should be applied by the relevant endpoints (like 
  /sync) to reduce unnecessary compute at this scope. Returns the event in the
  format and with fields specified by the filter, or `nil` if the event was 
  rejected by the filter.
  """
  # TOIMPL: ephemeral events...which would not be a %PDU{}
  def apply(%__MODULE__{} = filter, %{} = event), do: apply(filter.definition, event)

  def apply(%{} = filter, %PDU{} = pdu) do
    apply(filter, pdu |> Map.from_struct() |> Map.new(fn {k, v} -> {to_string(k), v} end))
  end

  def apply(%{} = filter, event) do
    event_filter_key = if is_nil(event["state_key"]), do: "timeline", else: "state"
    filter_fxns = [&contains_url?/2, &not_sender?/2, &sender?/2, &not_types?/2, &types?/2]
    formatter = if Map.get(filter, "event_format", "client") == "client", do: &RadioBeam.client_event/1, else: & &1

    if Enum.all?(filter_fxns, & &1.(filter["room"][event_filter_key], event)) do
      event |> take_fields(filter["event_fields"]) |> formatter.()
    else
      nil
    end
  end

  defp take_fields(%{} = event, nil), do: event

  defp take_fields(%{} = event, event_fields) do
    event_fields
    |> Stream.map(&String.split(&1, "."))
    |> Enum.reduce(%{}, fn path, new_event ->
      put_nested(new_event, path, get_in(event, path))
    end)
  end

  defp put_nested(data, path, value) do
    put_in(data, Enum.map(path, &Access.key(&1, %{})), value)
  end

  defp contains_url?(%{"contains_url" => true}, %{"content" => %{"url" => _}}), do: true
  defp contains_url?(%{"contains_url" => true}, _event), do: false
  defp contains_url?(%{"contains_url" => false}, %{"content" => %{"url" => _}}), do: false
  defp contains_url?(%{"contains_url" => false}, _event), do: true
  defp contains_url?(_filter, _event), do: true

  # TOIMPL include_redundant_members, lazy_load_members, unread_thread_notifications

  defp not_sender?(%{"not_senders" => excluded_senders}, event), do: event["sender"] not in excluded_senders
  defp not_sender?(_filter, _event), do: true

  defp sender?(%{"senders" => allowed_senders}, event), do: event["sender"] in allowed_senders
  defp sender?(_filter, _event), do: true

  defp not_types?(%{"not_types" => excluded_types}, event), do: not types?(%{"types" => excluded_types}, event)
  defp not_types?(_filter, _event), do: true

  defp types?(%{"types" => included_types}, event) do
    Enum.any?(included_types, fn t ->
      # I'm assuming "A '*' can be used as a wildcard" means only a single 
      # astrix can be used. Can't imagine a client wanting to use 2+
      case String.split(t, "*") do
        [type] -> type == event["type"]
        ["", type] -> String.ends_with?(event["type"], type)
        [type, ""] -> String.starts_with?(event["type"], type)
        [type_s, type_e] -> String.starts_with?(event["type"], type_s) and String.ends_with?(event["type"], type_e)
      end
    end)
  end

  defp types?(_filter, _event), do: true
end
