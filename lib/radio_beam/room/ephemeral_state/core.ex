defmodule RadioBeam.Room.EphemeralState.Core do
  alias RadioBeam.Room.EphemeralState

  @max_timeout_ms :timer.seconds(30)
  def max_timeout_ms, do: @max_timeout_ms

  def new!, do: %EphemeralState{}

  def put_typing(%EphemeralState{} = state, "@" <> _ = user_id, timeout) when is_integer(timeout) do
    {:ok, timer} = timeout |> clamp_timeout() |> :timer.send_after({:delete_typing, user_id})

    update_in(state.actively_typing[user_id], fn
      nil ->
        timer

      old_timer ->
        :timer.cancel(old_timer)
        timer
    end)
  end

  def all_typing(%EphemeralState{} = state), do: state.actively_typing |> Stream.map(&elem(&1, 0)) |> Enum.uniq()

  def delete_typing(%EphemeralState{} = state, "@" <> _ = user_id) when is_map_key(state.actively_typing, user_id) do
    {:ok, :cancel} = :timer.cancel(state.actively_typing[user_id])
    update_in(state.actively_typing, &Map.delete(&1, user_id))
  end

  def delete_typing(%EphemeralState{} = state, _user_id), do: state

  defp clamp_timeout(timeout) when timeout in 1..@max_timeout_ms, do: timeout
  defp clamp_timeout(_timeout), do: @max_timeout_ms
end
