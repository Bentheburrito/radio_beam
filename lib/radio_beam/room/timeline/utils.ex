defmodule RadioBeam.Room.Timeline.Utils do
  @moduledoc """
  Utility functions for Timeline
  """

  @doc """
  Encodes a list of event IDs into a `since` token that can be provided in the
  `next_batch` or `prev_batch` field of a sync response, or the /messages
  endpoint.

  NOTE: the length of this token grows linearly with the number of event IDs.
  This may begin to become an issue for users in 100s of rooms (or more).
  Consider `:zlib` when the length of `event_ids` exceeds a certain size.

    iex> Utils.encode_since_token(["$2feFTNOauB6SwzuhkqcelJdqyyolUMYTN6SfLWY9MJ8=", "$YF3P23hUffTxMiR05ZEPdhXaRPpzaW-XC1zqcPmu1rE="])
    "batch:2feFTNOauB6SwzuhkqcelJdqyyolUMYTN6SfLWY9MJ8=YF3P23hUffTxMiR05ZEPdhXaRPpzaW-XC1zqcPmu1rE="
  """
  def encode_since_token(event_ids) do
    for "$" <> hash64 <- event_ids, into: "batch:", do: hash64
  end

  @doc """
  Decodes a since token (created with `encode_since_token/1`) back into a list
  of event IDs.

    iex> Utils.decode_since_token("batch:2feFTNOauB6SwzuhkqcelJdqyyolUMYTN6SfLWY9MJ8=YF3P23hUffTxMiR05ZEPdhXaRPpzaW-XC1zqcPmu1rE=")
    ["$2feFTNOauB6SwzuhkqcelJdqyyolUMYTN6SfLWY9MJ8=", "$YF3P23hUffTxMiR05ZEPdhXaRPpzaW-XC1zqcPmu1rE="]
  """
  def decode_since_token("batch:" <> token) when rem(byte_size(token), 44) == 0 do
    for hash64 <- Enum.map(0..(byte_size(token) - 1)//44, &binary_slice(token, &1..(&1 + 43))) do
      "$" <> hash64
    end
  end
end
