defmodule RadioBeam.Room.EventGraph.PaginationToken do
  alias RadioBeam.Room
  alias RadioBeam.Room.View.Core.Timeline.TopologicalID

  @attrs ~w|arrival_key direction event_ids|a
  @enforce_keys @attrs
  defstruct @attrs

  @type t() :: %__MODULE__{
          direction: :forward | :backward,
          room_id_order_id_pairs: [{Room.id(), TopologicalID.t()}]
        }

  def new(room_id, %TopologicalID{}, dir), do: new([{room_id, pdu}], dir)

  def new(pairs, direction) when is_list(pairs) and direction in [:forward, :backward] do
    %__MODULE__{
      direction: direction,
      room_id_order_id_pairs: pairs
    }
  end

  # NOTE: the length of this token grows linearly with the number of event IDs.
  # This may begin to become an issue for users in 100s of rooms (or more).
  # Consider `:zlib` when the length of `event_ids` exceeds a certain size.
  def encode(%__MODULE__{direction: dir, room_id_order_id_pairs: pairs}) do
    for {"!" <> _ = room_id, %TopologicalID{} = order_id} <- pairs,
        into: "batch:#{dir}:",
        do: "#{Base.url_encode64(room_id)}:#{order_id}:"
  end

  def parse("batch:" <> token) do
    with [dir_string, pairs_string] <- String.split(token, ":", parts: 2),
         {:ok, dir} <- parse_direction(dir_string),
         {:ok, pairs} <- parse_pairs(pairs_string) do
      {:ok, %__MODULE__{direction: dir, room_id_order_id_pairs: pairs}}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp parse_direction("forward"), do: {:ok, :forward}
  defp parse_direction("backward"), do: {:ok, :backward}
  defp parse_direction(_invalid), do: :error

  defp parse_pairs(pairs_string), do: parse_pairs(pairs_string, [])

  defp parse_pairs(pairs_string, pairs) do
    with {:ok, maybe_room_id, maybe_order_id, rest} <- parse_pairs_string(pairs_string),
         {:ok, room_id} <- validate_room_id(maybe_room_id),
         {:ok, order_id} <- validate_order_id(maybe_order_id) do
      parse_pairs(rest, [{room_id, order_id} | pairs])
    end
  end

  defp parse_pairs_string(pairs_string) do
    case String.split(pairs_string, ":", parts: 3) do
      [maybe_room_id, maybe_order_id, rest] -> {:ok, maybe_room_id, maybe_order_id, rest}
      _else -> {:error, :invalid}
    end
  end

  defp validate_room_id(room_id) do
    case Base.url_decode64(room_id) do
      {:ok, "!" <> _ = room_id} -> room_id
      :error -> {:error, :invalid}
    end
  end

  defp validate_order_id(order_id), do: TopologicalID.parse_string(order_id)

  defimpl Jason.Encoder do
    def encode(token, opts), do: Jason.Encode.string(RadioBeam.Room.EventGraph.PaginationToken.encode(token), opts)
  end
end
