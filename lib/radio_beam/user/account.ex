defmodule RadioBeam.User.Account do
  alias RadioBeam.User.EventFilter
  alias RadioBeam.Repo
  alias RadioBeam.User

  @doc """
  Create and save a new event filter for the given user.
  """
  @spec upload_filter(User.id(), raw_filter_definition :: map()) :: {:ok, EventFilter.id()} | {:error, :not_found}
  def upload_filter(user_id, raw_definition) do
    filter = EventFilter.new(raw_definition)

    Repo.one_shot(fn ->
      with {:ok, %User{} = user} <- User.get(user_id, lock: :write) do
        user |> User.put_event_filter(filter) |> Memento.Query.write()
        {:ok, filter.id}
      end
    end)
  end
end
