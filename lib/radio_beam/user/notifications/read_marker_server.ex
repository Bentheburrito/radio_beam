defmodule RadioBeam.User.Notifications.ReadMarkerServer do
  @moduledoc """
  Simple GenServer that listens for read marker updates from users, and updates
  their read notifications accordingly.
  """
  use GenServer

  alias RadioBeam.PubSub
  alias RadioBeam.User.Notifications

  def start_link(opts) do
    gen_server_opts = Keyword.take(opts, [:name])
    GenServer.start_link(__MODULE__, nil, gen_server_opts)
  end

  @impl GenServer
  def init(nil) do
    :ok = PubSub.subscribe(PubSub.user_room_read_receipt_updated())
    {:ok, nil}
  end

  @impl GenServer
  def handle_info({:user_room_read_receipt_updated, room_id, user_id, thread_id, timestamp}, nil) do
    :ok = Notifications.mark_read(user_id, timestamp, room_id: room_id, thread_id: thread_id)
    {:noreply, nil}
  end
end
