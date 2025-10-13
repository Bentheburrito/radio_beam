defmodule RadioBeam.Room.Events.PaginationToken do
  alias RadioBeam.Room
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID

  @attrs ~w|direction room_id_order_id_pairs created_at_ms|a
  @enforce_keys @attrs
  defstruct @attrs

  @type t() :: %__MODULE__{
          direction: :forward | :backward,
          room_id_order_id_pairs: [{Room.id(), TopologicalID.t()}],
          created_at_ms: non_neg_integer()
        }

  def new(room_id, %TopologicalID{} = topo_id, dir, created_at), do: new(%{room_id => topo_id}, dir, created_at)

  def new(pairs, direction, created_at)
      when is_map(pairs) and direction in [:forward, :backward] and is_integer(created_at) and created_at >= 0 do
    %__MODULE__{
      direction: direction,
      room_id_order_id_pairs: pairs,
      created_at_ms: created_at
    }
  end

  def room_last_seen_order_id(%__MODULE__{} = token, room_id) do
    with :error <- Map.fetch(token.room_id_order_id_pairs, room_id), do: {:error, :not_found}
  end

  def created_at(%__MODULE__{created_at_ms: created_at}), do: created_at

  # NOTE: the length of this token grows linearly with the number of rooms..
  # This may begin to become an issue for users in 100s of rooms (or more).
  # Consider `:zlib` when the length of `event_ids` exceeds a certain size.
  def encode(%__MODULE__{direction: dir, room_id_order_id_pairs: pairs, created_at_ms: created_at}) do
    for {"!" <> _ = room_id, %TopologicalID{} = order_id} <- pairs,
        into: "batch:#{dir}:#{created_at}",
        do: ":#{Base.url_encode64(room_id)}:#{order_id}"
  end

  def parse("batch:" <> token) do
    with [dir_string, created_at_string, pairs_string] <- String.split(token, ":", parts: 3),
         {:ok, dir} <- parse_direction(dir_string),
         {:ok, created_at} <- parse_created_at(created_at_string),
         {:ok, pairs} <- parse_pairs(pairs_string) do
      {:ok, %__MODULE__{direction: dir, room_id_order_id_pairs: pairs, created_at_ms: created_at}}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp parse_direction("forward"), do: {:ok, :forward}
  defp parse_direction("backward"), do: {:ok, :backward}
  defp parse_direction(_invalid), do: :error

  defp parse_created_at(created_at_string) do
    case Integer.parse(created_at_string) do
      {created_at, ""} -> {:ok, created_at}
      :error -> {:error, :invalid}
    end
  end

  defp parse_pairs(pairs_string), do: parse_pairs(pairs_string, %{})

  defp parse_pairs(:done, pairs), do: {:ok, pairs}

  defp parse_pairs(pairs_string, pairs) do
    with {:ok, maybe_room_id, maybe_order_id, rest} <- parse_pairs_string(pairs_string),
         {:ok, room_id} <- validate_room_id(maybe_room_id),
         {:ok, order_id} <- validate_order_id(maybe_order_id) do
      parse_pairs(rest, Map.put(pairs, room_id, order_id))
    end
  end

  defp parse_pairs_string(pairs_string) do
    case String.split(pairs_string, ":", parts: 3) do
      [maybe_room_id, maybe_order_id] -> {:ok, maybe_room_id, maybe_order_id, :done}
      [maybe_room_id, maybe_order_id, rest] -> {:ok, maybe_room_id, maybe_order_id, rest}
      _else -> {:error, :invalid}
    end
  end

  defp validate_room_id(room_id) do
    case Base.url_decode64(room_id) do
      {:ok, "!" <> _ = room_id} -> {:ok, room_id}
      :error -> {:error, :invalid}
    end
  end

  defp validate_order_id(order_id), do: TopologicalID.parse_string(order_id)

  defimpl Jason.Encoder do
    def encode(token, opts), do: Jason.Encode.string(RadioBeam.Room.EventGraph.PaginationToken.encode(token), opts)
  end
end

