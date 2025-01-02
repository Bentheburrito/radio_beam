defmodule RadioBeam.Device.OneTimeKeyRing do
  @moduledoc """
  This module defines functions for managing a Device's one-time and fallback
  keys.
  """

  defstruct one_time_keys: %{}, fallback_keys: %{}

  def new, do: %__MODULE__{}

  def put_otks(%__MODULE__{} = otk_ring, keys_map) do
    new_otks =
      for {algo_by_key_id, content} <- keys_map, reduce: otk_ring.one_time_keys do
        acc ->
          [algo, key_id] = String.split(algo_by_key_id, ":")
          content = Map.put(content, "id", key_id)
          # One-time keys are given out in the order that they were uploaded via
          # /keys/upload. (All keys uploaded within a given call to /keys/upload are
          # considered equivalent in this regard; no ordering is specified within
          # them.)
          Map.update(acc, algo, [content], &(&1 ++ [content]))
      end

    %__MODULE__{otk_ring | one_time_keys: new_otks}
  end

  def put_fallback_keys(%__MODULE__{} = otk_ring, keys_map) do
    fallback_keys =
      for {algo_by_key_id, content} <- keys_map, reduce: otk_ring.fallback_keys do
        acc ->
          [algo, key_id] = String.split(algo_by_key_id, ":")
          content = content |> Map.put("id", key_id) |> Map.put("used?", false)
          # There can only be at most one key per algorithm uploaded, and the server
          # will only persist one key per algorithm.
          Map.put(acc, algo, content)
      end

    %__MODULE__{otk_ring | fallback_keys: fallback_keys}
  end

  # def claim_otk(%__MODULE__{one_time_keys: [key | rest]} = otk_ring), do: {key, %__MODULE__{otk_ring | one_time_keys: rest}}
  # def claim_otk(%__MODULE__{one_time_keys: [], fallback_key: nil} = otk_ring), do: {key, %__MODULE__{otk_ring | one_time_keys: rest}}
end
