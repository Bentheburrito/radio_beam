defmodule RadioBeam.Room.View.Core do
  @moduledoc """
  A View calculates a read model given a series of room events/PDUs. An
  instance of a view is called a "view state".
  """
  alias RadioBeam.Room
  alias RadioBeam.Room.PDU
  alias RadioBeam.Room.View.Core.Participating
  alias RadioBeam.Room.View.Core.RelatedEvents
  alias RadioBeam.Room.View.Core.Timeline

  @views [
    Participating,
    RelatedEvents,
    Timeline
  ]

  def handle_pdu(%Room{} = room, %PDU{} = pdu, deps) do
    %{fetch_view: fetch_view, save_view!: save_view!, broadcast!: broadcast!} = deps

    for view <- @views, {:ok, view_key} <- [view.key_for(room, pdu)] do
      view_state =
        case fetch_view.(view_key) do
          {:ok, %^view{} = view_state} -> view_state
          {:error, :not_found} -> view.new!()
        end

      view_state
      |> view.handle_pdu(room, pdu)
      |> maybe_broadcast(broadcast!)
      |> save_view!.(view_key)
    end
  end

  defp maybe_broadcast({view_state, pubsub_messages}, broadcast!) do
    for {pubsub_topic, pubsub_message} <- pubsub_messages do
      broadcast!.(pubsub_topic, pubsub_message)
    end

    view_state
  end

  defp maybe_broadcast(view_state, _broadcast!), do: view_state
end
