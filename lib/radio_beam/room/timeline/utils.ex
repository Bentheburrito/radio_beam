defmodule RadioBeam.Room.Timeline.Utils do
  def encode_since_token(event_ids) do
    for "$" <> hash64 <- event_ids, into: "batch:", do: hash64
  end

  def decode_since_token("batch:" <> token) when rem(byte_size(token), 44) == 0 do
    for hash64 <- Enum.map(0..(byte_size(token) - 1)//44, &binary_slice(token, &1..(&1 + 43))) do
      "$" <> hash64
    end
  end
end
