defmodule RadioBeam.Room.Timeline.LazyLoadMembersCache do
  @moduledoc """
  This GenServer owns the ETS table that caches which user's room memberships
  are known to devices, aiding in reducing the number of
  [redundant membership events](https://spec.matrix.org/latest/client-server-api/#lazy-loading-room-members)
  sent in sync responses.

  TODO: entries in the cache should expire after a while
  """
  use GenServer

  alias RadioBeam.Room
  alias RadioBeam.User
  alias RadioBeam.Room.Timeline.LazyLoadMembersCache, as: Self

  ### API ###

  def start_link(init_arg) do
    GenServer.start_link(Self, init_arg, name: Self)
  end

  @spec get([Room.id()], device_id :: String.t()) :: %{Room.id() => MapSet.t(User.id())}
  def get(room_ids, device_id) do
    match_spec = for room_id <- room_ids, do: {{{room_id, device_id}, :"$1"}, [], [:"$_"]}

    case :ets.select(Self.Table, match_spec) do
      [] ->
        %{}

      matches ->
        Enum.reduce(matches, %{}, fn {{room_id, _}, user_id}, acc ->
          Map.update(acc, room_id, MapSet.new([user_id]), &MapSet.put(&1, user_id))
        end)
    end
  end

  def put(device_id, room_id, "@" <> _ = user_id), do: put(device_id, room_id, [user_id])

  def put(device_id, room_id, user_ids) when is_list(user_ids) do
    for user_id <- user_ids, do: :ets.insert(Self.Table, {{room_id, device_id}, user_id})
    true
  end

  def mark_dirty(room_id, user_id), do: :ets.match_delete(Self.Table, {{room_id, :_}, user_id})

  ### IMPL

  @impl GenServer
  def init(_arg) do
    table_id = :ets.new(Self.Table, [:public, :bag, :named_table, read_concurrency: true])
    {:ok, table_id}
  end
end
