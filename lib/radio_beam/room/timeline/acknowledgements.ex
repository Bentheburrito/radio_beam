defmodule RadioBeam.Room.Timeline.Acknowledgements do
  @moduledoc """
  API for sending acknowledgements and markers of timeline events.
  """
  alias RadioBeam.Room
  alias RadioBeam.Room.Timeline.Acknowledgements.Server
  alias RadioBeam.Room.View
  alias RadioBeam.User

  def put_read_receipt(room_id, user_id, event_id, "m.fully_read", :unthreaded) do
    User.put_fully_read(user_id, room_id, %{"event_id" => event_id})
  end

  def put_read_receipt(_room_id, _user_id, _event_id, "m.fully_read", _thread_id),
    do: {:error, :fully_read_invalid_with_thread_id}

  def put_read_receipt(room_id, user_id, event_id, receipt_type, thread_id) do
    with {:ok, event} <- validate_readable_event(room_id, user_id, event_id),
         :ok <- validate_thread_id_for_event(room_id, user_id, event, thread_id) do
      Server.put_read_receipt(room_id, user_id, event_id, receipt_type, thread_id)
    end
  end

  defp validate_readable_event(room_id, user_id, event_id) do
    with {:ok, event_stream} <- View.get_events(room_id, user_id, [event_id], _bundle_aggregates? = false),
         [event] <- Enum.take(event_stream, 2) do
      {:ok, event}
    else
      _ -> {:error, :not_found}
    end
  end

  @max_children 100
  defp validate_thread_id_for_event(room_id, user_id, event, "$" <> _ = thread_id) do
    with {:ok, _thread_root} <- validate_readable_event(room_id, user_id, thread_id),
         # TODO: don't need to fetch children if `in_thread?(event)` below short circuits
         {:ok, child_events, _recurse} <- Room.get_children(room_id, user_id, thread_id, @max_children, recurse?: true) do
      # NOTE: this Enum.find isn't completely accurate - according to the spec,
      # relations pointing to the thread root w/out an m.thread rel somewhere
      # in the relation graph are not threaded
      if in_thread?(event, thread_id) or Enum.find(child_events, false, &(&1.id == event.id)) do
        :ok
      else
        {:error, :not_a_thread}
      end
    end
  end

  defp validate_thread_id_for_event(_room_id, _user_id, _e, thread_id) when thread_id in ~w|main unthreaded|a, do: :ok
  defp validate_thread_id_for_event(_room_id, _user_id, _event, _thread_id), do: {:error, :invalid_thread_id}

  defp in_thread?(event, thread_id),
    do: match?(%{"rel_type" => "m.thread", "event_id" => ^thread_id}, event.content["m.relates_to"])

  def get_all_receipts(room_id, user_id, since_ts) do
    receipts = Server.get_all_receipts(room_id, user_id, since_ts)

    event_stream = View.get_events!(room_id, user_id, Map.keys(receipts), false)
    visible_event_ids = Enum.map(event_stream, & &1.id)

    Map.take(receipts, visible_event_ids)
  end
end
