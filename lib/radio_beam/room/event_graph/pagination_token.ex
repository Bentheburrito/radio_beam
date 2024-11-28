defmodule RadioBeam.Room.EventGraph.PaginationToken do
  alias RadioBeam.PDU

  @attrs ~w|arrival_key direction event_ids|a
  @enforce_keys @attrs
  defstruct @attrs

  @type t() :: %__MODULE__{
          arrival_key: {non_neg_integer(), integer()},
          direction: :forward | :backward,
          event_ids: [PDU.event_id()]
        }

  def new(%PDU{} = pdu, dir), do: new([pdu], dir)

  def new(pdus, direction) when is_list(pdus) and direction in [:forward, :backward] do
    %__MODULE__{
      arrival_key: pdus |> Stream.map(&{&1.arrival_time, &1.arrival_order}) |> Enum.max(),
      direction: direction,
      event_ids: Enum.map(pdus, & &1.event_id)
    }
  end

  def new(fallback_timestamp, direction) when is_integer(fallback_timestamp) and direction in [:forward, :backward] do
    %__MODULE__{
      arrival_key: {fallback_timestamp, 0},
      direction: direction,
      event_ids: []
    }
  end

  def encode(%__MODULE__{arrival_key: {arrival_time, arrival_order}, direction: dir, event_ids: ids}) do
    for "$" <> hash64 <- ids, into: "batch:#{arrival_time}:#{arrival_order}:#{dir}:", do: "#{hash64}"
  end

  def parse("batch:" <> token) do
    with [time_string, order_string, dir_string, hash64s] when rem(byte_size(hash64s), 44) == 0 <-
           String.split(token, ":"),
         {arrival_time, ""} <- Integer.parse(time_string),
         {arrival_order, ""} <- Integer.parse(order_string),
         {:ok, dir} <- parse_direction(dir_string) do
      event_ids =
        for hash64 <- Enum.map(0..(byte_size(hash64s) - 1)//44, &binary_slice(hash64s, &1..(&1 + 43))) do
          "$" <> hash64
        end

      {:ok, %__MODULE__{arrival_key: {arrival_time, arrival_order}, direction: dir, event_ids: event_ids}}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp parse_direction("forward"), do: {:ok, :forward}
  defp parse_direction("backward"), do: {:ok, :backward}
  defp parse_direction(_invalid), do: :error

  defimpl Jason.Encoder do
    def encode(token, opts), do: Jason.Encode.string(RadioBeam.Room.EventGraph.PaginationToken.encode(token), opts)
  end
end
