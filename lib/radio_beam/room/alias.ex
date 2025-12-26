defmodule RadioBeam.Room.Alias do
  @moduledoc """
  Represents a user-friendly name to reference a `RadioBeam.Room`.
  """

  alias Polyjuice.Util.Identifiers.V1.ServerName

  defstruct ~w|localpart server_name|a

  @type t() :: %__MODULE__{}

  # TOIMPL: check the room alias grammar
  @doc """
  Validate a room alias. Returns `{:ok, %Alias{}}` on success, or `{:error,
  :invalid_alias}`.
  """
  def new(alias_str) when is_binary(alias_str) do
    with {:ok, localpart, server_name} <- validate(alias_str) do
      {:ok, %__MODULE__{localpart: localpart, server_name: server_name}}
    end
  end

  defp validate(alias_str) do
    case String.split(alias_str, ":", parts: 3) do
      ["#" <> localpart | rest] ->
        # handle server names with a port like `homeserver.com:7547`
        server_name = Enum.join(rest, ":")

        cond do
          not String.valid?(localpart) or not String.printable?(localpart) -> {:error, :invalid_alias_localpart}
          not match?({:ok, _}, ServerName.parse(server_name)) -> {:error, :invalid_server_name}
          :else -> {:ok, localpart, server_name}
        end

      _ ->
        {:error, :invalid_alias}
    end
  end

  defimpl String.Chars do
    def to_string(alias), do: "##{alias.localpart}:#{alias.server_name}"
  end
end
