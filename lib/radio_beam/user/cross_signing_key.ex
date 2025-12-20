defmodule RadioBeam.User.CrossSigningKey do
  @moduledoc false
  @attrs ~w|algorithm id key signatures usages|a
  @enforce_keys @attrs
  defstruct @attrs

  alias RadioBeam.User
  alias Polyjuice.Util.JSON
  alias Polyjuice.Util.VerifyKey

  @type t() :: %__MODULE__{
          algorithm: String.t(),
          id: String.t(),
          key: binary(),
          signatures: map(),
          usages: [String.t()]
        }

  @typedoc """
  String-key params defining a CrossSigningKey, as defined in 
  [the spec](https://spec.matrix.org/latest/client-server-api/#post_matrixclientv3keysdevice_signingupload)
  """
  @type params() :: map()

  @type parse_error() :: {:error, :too_many_keys | :no_key_provided | :user_ids_do_not_match | :malformed_key}
  @type put_signature_error() :: :different_keys | :invalid_signature

  @doc """
  Convert a CrossSigningKey to a map as defined in the spec.
  """
  def to_map(%__MODULE__{} = csk, user_id) do
    init_map = %{
      "keys" => %{VerifyKey.id(csk) => Base.encode64(csk.key, padding: false)},
      "usage" => csk.usages,
      "user_id" => user_id
    }

    if map_size(csk.signatures) == 0 do
      init_map
    else
      Map.put(init_map, "signatures", csk.signatures)
    end
  end

  @doc """
  Parse a CrossSigningKey as defined in the spec
  """
  @spec parse(params :: map(), User.id()) :: {:ok, t()} | parse_error()
  def parse(%{"keys" => key, "usage" => usages, "user_id" => user_id} = params, user_id)
      when map_size(key) == 1 and is_list(usages) do
    signatures = Map.get(params, "signatures", %{})

    with {:ok, algo, id, key_base64} <- parse_key(key),
         {:ok, binary} <- Base.decode64(key_base64, padding: false, ignore: :whitespace) do
      {:ok, %__MODULE__{algorithm: algo, id: id, key: binary, signatures: signatures, usages: usages}}
    end
  end

  def parse(%{"keys" => keys}, _user_id) when map_size(keys) > 1, do: {:error, :too_many_keys}
  def parse(%{"keys" => keys}, _user_id) when map_size(keys) < 1, do: {:error, :no_key_provided}
  def parse(_params, _user_id), do: {:error, :user_ids_do_not_match}

  defp parse_key(key) do
    with [{algo_pub_key, key_value}] <- Map.to_list(key),
         [algo, id] <- String.split(algo_pub_key, ":") do
      {:ok, algo, id, key_value}
    else
      _ -> {:error, :malformed_key}
    end
  end

  @doc """
  Validates a new signature present in `csk_params_with_new_signature` made by
  `signer` of the given `t:CrossSigningKey`, `csk`. Returns an :ok tuple with
  the new signature added to `csk`'s `signatures` field if all checks pass, and
  an error tuple otherwise.
  """
  @spec put_signature(t(), User.id(), map(), User.id(), Polyjuice.Util.VerifyKey.t()) ::
          {:ok, t()} | {:error, put_signature_error()}
  def put_signature(%__MODULE__{} = csk, csk_user_id, csk_params_with_new_signature, signer_id, signer_key) do
    csk_params = Map.delete(csk_params_with_new_signature, "signatures")

    cond do
      # this equality check seems to just be for a better error message, since
      # if we just check the signature against `to_map(csk, user_id)`, it would
      # also fail
      csk |> to_map(csk_user_id) |> Map.delete("signatures") != csk_params ->
        {:error, :different_keys}

      JSON.signed?(csk_params_with_new_signature, signer_id, signer_key) ->
        signatures =
          RadioBeam.put_nested(
            csk.signatures,
            [signer_id, VerifyKey.id(csk)],
            csk_params_with_new_signature["signatures"][signer_id][VerifyKey.id(csk)]
          )

        {:ok, put_in(csk.signatures, signatures)}

      :else ->
        {:error, :invalid_signature}
    end
  end

  defimpl VerifyKey do
    def algorithm(%{algorithm: algo}), do: algo
    def id(%{algorithm: algo, id: id}), do: "#{algo}:#{id}"
    def version(%{id: id}), do: id

    def verify(%{algorithm: algo, key: key}, message, signature)
        when is_binary(key) and is_binary(message) and is_binary(signature) do
      case Base.decode64(signature, padding: false) do
        {:ok, binary_signature} -> verify(algo, message, binary_signature, key)
        :error -> {:error, :could_not_base64_decode}
      end
    end

    defp verify("ed25519", message, binary_signature, key) do
      :crypto.verify(:eddsa, :none, message, binary_signature, [key, :ed25519])
    end
  end
end
