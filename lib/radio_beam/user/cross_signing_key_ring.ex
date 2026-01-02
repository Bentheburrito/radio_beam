defmodule RadioBeam.User.CrossSigningKeyRing do
  @moduledoc false
  @attrs ~w|master self user last_cross_signing_change_at|a
  @enforce_keys @attrs
  defstruct @attrs

  alias RadioBeam.User
  alias RadioBeam.User.CrossSigningKey

  @type t() :: %__MODULE__{
          master: CrossSigningKey.t() | nil,
          self: CrossSigningKey.t() | nil,
          user: CrossSigningKey.t() | nil,
          last_cross_signing_change_at: non_neg_integer()
        }

  @type put_opt() ::
          {:master_key, CrossSigningKey.params()}
          | {:self_signing_key, CrossSigningKey.params()}
          | {:user_signing_key, CrossSigningKey.params()}
  @type put_opts() :: [put_opts()]

  def new, do: %__MODULE__{master: nil, self: nil, user: nil, last_cross_signing_change_at: 0}

  @doc "Put cross-signing keys for a user"
  @spec put(t(), User.id(), put_opts()) ::
          {:ok, User.KeyStore.t()}
          | {:error, :not_found | :missing_master_key | :missing_or_invalid_master_key_signatures}
          | CrossSigningKey.parse_error()
  def put(%__MODULE__{} = csk_ring, user_id, opts) do
    master_key = Keyword.get(opts, :master_key, csk_ring.master)
    self_signing_key = Keyword.get(opts, :self_signing_key, csk_ring.self)
    user_signing_key = Keyword.get(opts, :user_signing_key, csk_ring.user)

    with {:ok, master_key} <- parse_signing_key(master_key, user_id),
         {:ok, self_signing_key} <- parse_signing_key(self_signing_key, user_id),
         {:ok, user_signing_key} <- parse_signing_key(user_signing_key, user_id) do
      cond do
        # disallow uploading self-/user-signing keys if we have no master key to verify signatures
        is_nil(master_key) and (not is_nil(self_signing_key) or not is_nil(user_signing_key)) ->
          {:error, :missing_master_key}

        not valid_signing_keys?(master_key, self_signing_key, user_signing_key, user_id) ->
          {:error, :missing_or_invalid_master_key_signatures}

        :else ->
          {:ok,
           %__MODULE__{
             master: master_key,
             self: self_signing_key,
             user: user_signing_key,
             last_cross_signing_change_at: System.os_time(:millisecond)
           }}
      end
    end
  end

  # TOIMPL: …Servers therefore must ensure that device IDs will not collide with cross-signing public keys
  defp valid_signing_keys?(master_key, self_signing_key, user_signing_key, user_id) do
    signed?(self_signing_key, user_id, master_key) and signed?(user_signing_key, user_id, master_key)
  end

  defp parse_signing_key(nil, _user_id), do: {:ok, nil}
  defp parse_signing_key(%CrossSigningKey{} = csk, _user_id), do: {:ok, csk}
  defp parse_signing_key(params, user_id), do: CrossSigningKey.parse(params, user_id)

  # since the user/self signing keys are optional, they could be nil
  defp signed?(nil, _user_id, _key), do: true

  defp signed?(%CrossSigningKey{} = signed, user_id, key),
    do: Polyjuice.Util.JSON.signed?(CrossSigningKey.to_map(signed, user_id), user_id, key)
end
