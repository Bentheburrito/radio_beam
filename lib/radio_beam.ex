defmodule RadioBeam do
  @moduledoc """
  RadioBeam keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  @doc """
  Encodes a map (rather naively) into a canonical JSON string.
  """
  @spec canonical_encode(map()) :: String.t()
  def canonical_encode(to_encode) when is_map(to_encode) do
    to_encode
    |> deep_sort()
    |> Jason.encode()
  end

  defp deep_sort(pairs) do
    pairs
    |> Enum.map(fn
      {key, nested_value} when is_map(nested_value) -> {to_string(key), deep_sort(nested_value)}
      {key, nested_value} when is_list(nested_value) -> {to_string(key), Enum.map(nested_value, &deep_sort/1)}
      {key, value} when is_float(value) -> {to_string(key), floor(value)}
      {key, value} -> {to_string(key), value}
    end)
    |> Enum.sort()
    |> Jason.OrderedObject.new()
  end
end
