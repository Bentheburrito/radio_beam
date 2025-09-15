defmodule RadioBeam.Room.Timeline.Core do
  @moduledoc """
  Functional core for syncing with clients and reading the event graph.
  """

  alias RadioBeam.Room.View.Core.Timeline.Event
  alias RadioBeam.User.EventFilter

  @doc """
  Creates a new Enumerable `%Timeline{}` from the given event_stream, which
  lazily filters events that are appropriate to display in a timeline for the
  given `user_id`. Events are filtered by:

  - whether the user's membership and room history configuration allows them to
    view the event
  - whether the provided filter allows the given event
  - whether the user is ignoring the sender of the event

  The new event stream does not include bundled aggregations.
  """
  def from_event_stream(
        event_stream,
        event_stream_dir,
        user_id,
        user_membership_at_first_event,
        user_latest_known_join_pdu,
        filter,
        ignored_user_ids
      ) do
    event_stream
    |> Stream.transform(
      {user_membership_at_first_event, user_latest_known_join_pdu},
      &reject_unauthorized_events(&1, user_id, &2, event_stream_dir)
    )
    |> Stream.reject(&from_ignored_user?(&1, ignored_user_ids))
    |> Stream.filter(&EventFilter.allow_timeline_event?(filter, &1))
  end

  # this function assumes its reducing over consecutive events, thus it should
  # not be used when "seeking" through disconnected events in a timeline,
  # else it will not track memberships properly between each call
  defp reject_unauthorized_events(%Event{} = event, user_id, {user_membership_at_pdu, user_latest_known_join_pdu}, dir) do
    {user_membership_at_pdu, user_membership_before_pdu} =
      if event.type == "m.room.member" and event.state_key == user_id do
        {Map.fetch!(event.content, "membership"), get_in(event.unsigned["prev_content"]["membership"]) || "leave"}
      else
        {user_membership_at_pdu, user_membership_at_pdu}
      end

    user_membership_at_next_pdu =
      case dir do
        :backward -> user_membership_before_pdu
        :forward -> user_membership_at_pdu
      end

    user_joined_later? = user_joined_later?(event, user_latest_known_join_pdu)

    if user_authorized_to_view?(event, user_id, user_membership_at_pdu, user_joined_later?) do
      {[event], {user_membership_at_next_pdu, user_latest_known_join_pdu}}
    else
      {[], {user_membership_at_next_pdu, user_latest_known_join_pdu}}
    end
  end

  def user_authorized_to_view?(event, user_id, user_membership_at_pdu, user_joined_later?) do
    cond do
      visible?(user_membership_at_pdu, user_joined_later?, pdu.current_visibility) ->
        true

      # For m.room.history_visibility events themselves, the user should be
      # allowed to see the event if the history_visibility before or after the
      # event would allow them to see it
      event.type == "m.room.history_visibility" ->
        visible?(user_membership_at_pdu, user_joined_later?, pdu.content["history_visibility"])

      # Likewise, for the user’s own m.room.member events, the user should be
      # allowed to see the event if their membership before or after the event
      # would allow them to see it.
      event.type == "m.room.member" and event.state_key == user_id ->
        user_membership_before_pdu = get_in(event.unsigned["prev_content"]["membership"]) || "leave"
        visible?(user_membership_before_pdu, user_joined_later?, event.current_visibility)

      :else ->
        false
    end
  end

  def user_joined_later?(event, user_latest_known_join_pdu), do: PDU.compare(user_latest_known_join_pdu, event) == :gt

  defp visible?(user_membership_at_event, user_joined_later?, history_visibility) do
    history_visibility == "world_readable" or
      user_membership_at_event == "join" or
      (user_joined_later? and history_visibility == "shared") or
      (user_membership_at_event == "invite" and history_visibility == "invited" and user_joined_later?)
  end

  defp from_ignored_user?(event, ignored_user_ids), do: is_nil(event.state_key) and event.sender in ignored_user_ids
end
