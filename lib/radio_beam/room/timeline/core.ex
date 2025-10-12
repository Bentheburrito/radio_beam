defmodule RadioBeam.Room.Timeline.Core do
  @moduledoc """
  Functional core for syncing with clients and reading the event graph.
  """

  # alias RadioBeam.User.EventFilter

  #   @doc """
  #   Creates a new Enumerable from the given user_event_stream, lazily filtering
  #   for events that pass the given event filter and ignored_user_ids.
  #   """
  # def from_event_stream(user_event_stream, filter, ignored_user_ids) do
  #   user_event_stream
  #   |> Stream.reject(&from_ignored_user?(&1, ignored_user_ids))
  #   |> Stream.filter(&EventFilter.allow_timeline_event?(filter, &1))
  # end

  # defp from_ignored_user?(event, ignored_user_ids), do: is_nil(event.state_key) and event.sender in ignored_user_ids

  # def user_authorized_to_view?(event, user_id, user_membership_at_pdu, user_joined_later?) do
  #   cond do
  #     visible?(user_membership_at_pdu, user_joined_later?, event.current_visibility) ->
  #       true

  #     # For m.room.history_visibility events themselves, the user should be
  #     # allowed to see the event if the history_visibility before or after the
  #     # event would allow them to see it
  #     event.type == "m.room.history_visibility" ->
  #       visible?(user_membership_at_pdu, user_joined_later?, event.content["history_visibility"])

  #     # Likewise, for the user’s own m.room.member events, the user should be
  #     # allowed to see the event if their membership before or after the event
  #     # would allow them to see it.
  #     event.type == "m.room.member" and event.state_key == user_id ->
  #       user_membership_before_pdu = get_in(event.unsigned["prev_content"]["membership"]) || "leave"
  #       visible?(user_membership_before_pdu, user_joined_later?, event.current_visibility)

  #     :else ->
  #       false
  #   end
  # end

  # def user_joined_later?(event, user_latest_known_join_pdu), do: PDU.compare(user_latest_known_join_pdu, event) == :gt

  # defp visible?(user_membership_at_event, user_joined_later?, history_visibility) do
  #   history_visibility == "world_readable" or
  #     user_membership_at_event == "join" or
  #     (user_joined_later? and history_visibility == "shared") or
  #     (user_membership_at_event == "invite" and history_visibility == "invited" and user_joined_later?)
  # end
end
