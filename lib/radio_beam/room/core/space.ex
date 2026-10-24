defmodule RadioBeam.Room.Core.Space do
  @moduledoc """
  The spec does not explicitly say that homeservers must enforce the
  m.space.{parent,child} event type rules, only that they are "ignored."
  However, I think doing some reasonable validation at write-time in addition
  to the required specified read-time checks can't hurt.
  """
  alias RadioBeam.Room
  alias RadioBeam.Room.AuthorizedEvent
  alias RadioBeam.Room.Core.PowerLevels
  alias RadioBeam.Room.Chronicle

  @link_event_types ~w|m.space.parent m.space.child|
  def link_event_types, do: @link_event_types

  @doc """
  Given a `t:RadioBeam.Room` and an `t:RadioBeam.Room.AuthorizedEvent` in it,
  checks that the event, if it of type `m.space.child` or `m.space.parent`, is
  valid. A link is considered valid for each type as follows:

  ## m.space.child

  1. If an `m.space.child` event for the given room under `state_key` does not
     exist, the content of the event's `via` key must be a non-empty list. This
     prevents spuriously invalid child links from being sent into a room. If a
     valid `m.space.child` entry already exists in the room state, empty `via`
     contents will then be allowed in order to invalidate the link at a later
     time. This function does not perform any checks agains the room ID under
     `state_key` nor the servernames under `content.via`, except that the
     `state_key` begins with `!`.

  ## m.space.parent

  1. A similar check to the one described above for `m.space.child` events, but
     for `m.space.parent`.
  1. According to [the spec](https://spec.matrix.org/latest/client-server-api/#mspaceparent-relationships),
     The specified parent room must either have a corresponding `m.space.child`
     event, or the `sender` of this `m.space.parent` must be able to send such
     an event in that room. Otherwise, this `m.space.parent` event is
     considered unauthorized.
  """
  def validate_link(%Room{} = room, %AuthorizedEvent{type: "m.space.child"} = event, _deps) do
    if valid_child_link?(room, event), do: :ok, else: {:error, :invalid_space_child_link}
  end

  def validate_link(%Room{} = room, %AuthorizedEvent{type: "m.space.parent"} = event, deps) do
    with {:ok, %Room{} = parent_room} <- deps.fetch_room.(event.state_key) do
      if valid_parent_link?(room, event, parent_room) do
        :ok
      else
        {:error, :invalid_space_parent_link}
      end
    end
  end

  def validate_link(%Room{}, %AuthorizedEvent{}, _deps), do: :ok

  # Quoting from [the spec](https://spec.matrix.org/latest/client-server-api/#mspaceparent-relationships):
  #
  # To avoid situations where a room falsely claims it is part of a given
  # space, m.space.parent events should be ignored unless one of the following
  # is true:
  #
  # - A corresponding m.space.child event can be found in the supposed parent
  # space.
  # - The sender of the m.space.parent event has sufficient power level in
  # the supposed parent space to send m.space.child state events (there doesn’t
  # need to be a matching child event).
  defp valid_parent_link?(
         %Room{} = room,
         %AuthorizedEvent{type: "m.space.parent", sender: sender} = event,
         %Room{} = parent_room
       ) do
    (active_link?(event) or state_entry_present?(room, event.type, event.state_key, event.id)) and
      (child_of_room?(parent_room, Room.Core.room_id(room)) or
         sender_authz?(parent_room, sender))
  end

  defp child_of_room?(parent_room, child_room_id) do
    parent_room.chronicle
    |> Chronicle.get_state_mapping(:current_state, true)
    |> is_map_key({"m.space.child", child_room_id})
  end

  defp sender_authz?(parent_room, sender) do
    PowerLevels.can_send_event?(parent_room, sender, "m.space.child", "") == true
  end

  defp valid_child_link?(%Room{} = room, %AuthorizedEvent{type: "m.space.child", state_key: "!" <> _} = event) do
    active_link?(event) or state_entry_present?(room, event.type, event.state_key, event.id)
  end

  defp valid_child_link?(%Room{}, %AuthorizedEvent{}), do: false

  defp state_entry_present?(room, type, state_key, event_id) do
    state_mapping = Chronicle.get_state_mapping(room.chronicle, event_id, _apply_event_ids? = false)
    is_map_key(state_mapping, {type, state_key})
  end

  defp active_link?(%AuthorizedEvent{type: type, state_key: "!" <> _room_id} = event) when type in @link_event_types do
    case Map.get(event.content, "via", []) do
      [] -> false
      [_servername | _] -> true
      _else -> false
    end
  end

  defp active_link?(%AuthorizedEvent{}), do: false
end
