defmodule RadioBeam.Room.Timeline.Chunk do
  @moduledoc """
  A chunk of visible events in a user's timeline, as queried via /messages.
  """

  alias RadioBeam.User.EventFilter
  alias RadioBeam.Room.View.Core.Timeline.Event

  defstruct ~w|timeline_events state_events start end to_event|a

  def new(room, timeline_events, maybe_next_order_id, get_known_memberships_fxn, filter) do
    %__MODULE__{
      timeline_events: timeline_events,
      state_events: get_state_events(room, timeline_events, get_known_memberships_fxn, filter),
      start: timeline_events |> hd() |> start_token(),
      end: maybe_next_order_id,
      to_event: &encode_event(&1, room.version, filter)
    }
  end

  defp start_token(%Event{order_id: order_id}), do: order_id

  defp encode_event(%Event{} = event, room_version, _filter) do
    Event.to_map(event, room_version)
    # TOIMPL
    # |> EventFilter.take_fields(filter.fields)
  end

  defp get_state_events(room, timeline_events, get_known_memberships_fxn, filter) do
    ignore_memberships_from =
      if filter.state.memberships == :lazy do
        known_membership_map = get_known_memberships_fxn.()
        Map.get(known_membership_map, room.id, [])
      else
        []
      end

    timeline_events
    |> Stream.reject(&(&1.sender in ignore_memberships_from))
    |> Stream.uniq_by(& &1.sender)
    |> Enum.map(&(room.state |> Map.fetch!({"m.room.member", &1.sender}) |> Event.new!()))
  end

  defimpl Jason.Encoder do
    alias RadioBeam.Room.Timeline.Chunk

    def encode(%Chunk{} = chunk, opts) do
      %{
        chunk: Enum.map(chunk.timeline_events, chunk.to_event),
        state: Enum.map(chunk.state_events, chunk.to_event),
        start: chunk.start
      }
      |> maybe_put_end(chunk.end)
      |> Jason.Encode.map(opts)
    end

    defp maybe_put_end(to_encode, :no_more_events), do: to_encode
    defp maybe_put_end(to_encode, pagination_token), do: Map.put(to_encode, :end, pagination_token)
  end
end
