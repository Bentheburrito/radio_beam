defmodule RadioBeam.Room.Timeline.Chunk do
  @moduledoc """
  A chunk of visible events in a user's timeline, as queried via /messages.
  """

  alias RadioBeam.Room.EventGraph.PaginationToken

  defstruct ~w|timeline_events state_events start next_page room_version filter|a

  def new(room, timeline_events, direction, from, next_page_info, get_known_memberships_fxn, filter) do
    %__MODULE__{
      timeline_events: timeline_events,
      state_events: get_state_events(room, timeline_events, get_known_memberships_fxn, filter),
      start: start_token(hd(timeline_events), from, direction),
      next_page: next_page_info,
      room_version: room.version,
      filter: filter
    }
  end

  defp start_token(_first_pdu, {%PaginationToken{} = from, _dir}, _inferred_dir), do: from
  defp start_token(first_pdu, _root_or_tip, dir), do: PaginationToken.new(first_pdu, dir)

  defp get_state_events(room, timeline_events, get_known_memberships_fxn, filter) do
    ignore_memberships_from =
      if filter.state.memberships == :lazy do
        known_membership_map = get_known_memberships_fxn.()
        Map.get(known_membership_map, room.id, [])
      else
        []
      end

    timeline_events
    |> Stream.map(& &1.sender)
    |> Stream.reject(&(&1 in ignore_memberships_from))
    |> Stream.uniq()
    |> Enum.map(&Map.fetch!(room.state, {"m.room.member", &1}))
  end

  defimpl Jason.Encoder do
    alias RadioBeam.Room.Timeline.Chunk

    def encode(%Chunk{} = chunk, opts) do
      format = String.to_existing_atom(chunk.filter.format)

      to_event = fn pdu ->
        pdu
        |> RadioBeam.PDU.to_event(chunk.room_version, :strings, format)
        |> RadioBeam.User.EventFilter.take_fields(chunk.filter.fields)
      end

      %{
        chunk: Enum.map(chunk.timeline_events, to_event),
        state: Enum.map(chunk.state_events, to_event),
        start: chunk.start
      }
      |> maybe_put_end(chunk.next_page)
      |> Jason.Encode.map(opts)
    end

    defp maybe_put_end(to_encode, :no_more_events), do: to_encode
    defp maybe_put_end(to_encode, pagination_token), do: Map.put(to_encode, :end, pagination_token)
  end
end
