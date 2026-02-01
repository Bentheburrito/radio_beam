defmodule RadioBeam.Sync.Source.AccountDataUpdates do
  @moduledoc """
  Returns `:ok` to the sink when a user's Client Config is updated. This Source
  doesn't actually send the new data, it just acts as a way to short-circuit a
  /sync call where all sources are otherwise `:waiting`.
  """
  @behaviour RadioBeam.Sync.Source

  alias RadioBeam.PubSub
  alias RadioBeam.Sync.Source
  alias RadioBeam.User

  @impl Source
  def top_level_path(_key, _result), do: ["account_data"]

  @impl Source
  def inputs, do: [:user_id]

  @impl Source
  def run(inputs, key, sink_pid) do
    user_id = inputs.user_id

    user_id
    |> PubSub.account_data_updated()
    |> PubSub.subscribe()

    Source.notify_waiting(sink_pid, key)

    receive do
      {:account_data_updated, ^user_id} ->
        {:ok, account_data} = User.get_account_data(user_id)
        {:ok, account_data.global, nil}
    end
  end
end
