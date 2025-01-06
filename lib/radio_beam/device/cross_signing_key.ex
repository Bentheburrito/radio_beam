defmodule RadioBeam.Device.CrossSigningKey do
  @attrs ~w|algorithm id key signatures usages|a
  @enforce_keys @attrs
  defstruct @attrs

  alias Polyjuice.Util.VerifyKey

  @type t() :: %__MODULE__{
          algorithm: String.t(),
          id: String.t(),
          key: binary(),
          signatures: map() | :none,
          usages: [String.t()]
        }

  @type parse_error() :: {:error, :too_many_keys | :no_key_provided | :user_ids_do_not_match | :malformed_key}

  @doc """
  Convert a CrossSigningKey to a map as defined in the spec.
  """
  def to_map(%__MODULE__{} = csk, user_id) do
    init_map = %{
      "keys" => %{VerifyKey.id(csk) => Base.encode64(csk.key, padding: false)},
      "usage" => csk.usages,
      "user_id" => user_id
    }

    if is_nil(csk.signatures) or csk.signatures == :none do
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
    signatures = Map.get(params, "signatures", :none)

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
