defmodule RadioBeam.Device.Table do
  @moduledoc """
  ❗This is a private module intended to only be used by Device and Device.Message
  """
  @attrs [
    :user_id_device_id,
    :display_name,
    :access_token,
    :refresh_token,
    :prev_refresh_token,
    :expires_at,
    :messages,
    :master_key,
    :self_signing_key,
    :user_signing_key,
    :identity_keys,
    :one_time_key_ring
  ]
  use Memento.Table,
    attributes: @attrs,
    index: [:access_token, :refresh_token, :prev_refresh_token],
    type: :set

  alias RadioBeam.Device
  alias RadioBeam.Repo
  alias RadioBeam.User

  def persist(%Device{} = device) do
    case User.get(device.user_id) do
      {:error, :not_found} ->
        {:error, :user_does_not_exist}

      {:ok, %User{}} ->
        %__MODULE__{} = device |> from_device() |> Memento.Query.write()
        {:ok, device}
    end
  end

  @doc "Gets a %Device{}"
  def get(user_id, device_id, opts) do
    opts = Keyword.put(opts, :coerce, false)

    Repo.one_shot(fn ->
      case Memento.Query.read(__MODULE__, {user_id, device_id}, opts) do
        nil -> {:error, :not_found}
        record -> {:ok, to_device(record)}
      end
    end)
  end

  def get_all_by_user(user_id) do
    match_head = __MODULE__.__info__().query_base
    match_spec = [{put_elem(match_head, 1, {user_id, :_}), [], [:"$_"]}]

    Repo.one_shot(fn ->
      case Memento.Query.select_raw(__MODULE__, match_spec, coerce: false) do
        records -> {:ok, Enum.map(records, &to_device/1)}
      end
    end)
  end

  @spec get_by_access_token(access_token :: binary()) :: Device.t() | {:error, :not_found}
  def get_by_access_token(access_token) do
    Repo.one_shot(fn ->
      case Memento.Query.select(__MODULE__, {:==, :access_token, access_token}, coerce: false, limit: 1) do
        {[device], _} -> {:ok, to_device(device)}
        _ -> {:error, :not_found}
      end
    end)
  end

  def get_by_refresh_token(refresh_token, lock \\ :read) do
    guard = {:or, {:==, :refresh_token, refresh_token}, {:==, :prev_refresh_token, refresh_token}}

    Repo.one_shot(fn ->
      case Memento.Query.select(__MODULE__, guard, coerce: false, limit: 1, lock: lock) do
        {[device], _} -> {:ok, to_device(device)}
        _ -> {:error, :not_found}
      end
    end)
  end

  defp to_device(
         {__MODULE__, {user_id, device_id}, display_name, access_token, refresh_token, prev_refresh_token, expires_at,
          messages, master_key, self_signing_key, user_signing_key, identity_keys, one_time_key_ring}
       ) do
    %Device{
      id: device_id,
      user_id: user_id,
      display_name: display_name,
      access_token: access_token,
      refresh_token: refresh_token,
      prev_refresh_token: prev_refresh_token,
      expires_at: expires_at,
      messages: messages,
      master_key: master_key,
      self_signing_key: self_signing_key,
      user_signing_key: user_signing_key,
      identity_keys: identity_keys,
      one_time_key_ring: one_time_key_ring
    }
  end

  defp from_device(%Device{} = device) do
    struct(%__MODULE__{user_id_device_id: {device.user_id, device.id}}, Map.from_struct(device))
  end
end
