defmodule RadioBeam.User.Device.Keys do
  @moduledoc """
  Interface for a device's identity and one-time keys
  """

  alias RadioBeam.Repo
  alias RadioBeam.User
  alias RadioBeam.User.Device

  def put(%User{} = user, device_id, opts) do
    with {:ok, %User{} = user} <- Device.put_keys(user, device_id, opts) do
      Repo.one_shot(fn -> {:ok, Memento.Query.write(user)} end)
    end
  end

  def claim_otks(user_device_algo_map) do
    Repo.one_shot(fn ->
      user_map = user_device_algo_map |> Map.keys() |> User.all() |> Map.new(&{&1.id, &1})

      user_device_key_map =
        user_device_algo_map
        |> Map.new(fn {user_id, device_algo_map} -> {Map.fetch!(user_map, user_id), device_algo_map} end)
        |> Device.claim_otks()

      Map.new(user_device_key_map, fn {%User{} = updated_user, device_key_map} ->
        Memento.Query.write(updated_user)
        {updated_user.id, device_key_map}
      end)
    end)
  end
end
