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

  def claim_otk(%__MODULE__{} = otk_ring, algorithm) do
    with :none <- pop_otk(otk_ring, algorithm),
         :none <- get_fallback_key(otk_ring, algorithm) do
      {:error, :not_found}
    end
  end

  defp pop_otk(otk_ring, algorithm) do
    case otk_ring.one_time_keys do
      %{^algorithm => [key | rest]} ->
        {:ok, {key, put_in(otk_ring.one_time_keys[algorithm], rest)}}

      _else ->
        :none
    end
  end

  defp get_fallback_key(otk_ring, algorithm) do
    case otk_ring.fallback_keys do
      %{^algorithm => key} ->
        {:ok, {key, put_in(otk_ring.fallback_keys[algorithm]["used?"], true)}}

      _else ->
        :none
    end
  end
end
