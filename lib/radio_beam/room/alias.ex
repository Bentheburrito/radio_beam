defmodule RadioBeam.Room.Alias do
  @moduledoc """
  This table maps room aliases to room IDs
  """

  use Memento.Table,
    attributes: [:alias_tuple, :room_id],
    type: :set

  alias RadioBeam.Repo

  @type t() :: %__MODULE__{}

  def dump!(alias), do: alias
  def load!(alias), do: alias

  # TOIMPL: check the room alias grammar
  @doc """
  Adds a new room alias mapping. Returns `{:ok, %Alias{}}` on success, or
  `{:error, error}` otherwise, where `error` is either `:room_does_not_exist` or
  `:alias_in_use`.
  """
  def put(alias, room_id) do
    with {:ok, alias_localpart, server_name} <- validate(alias) do
      alias_tuple = {alias_localpart, server_name}

      Repo.transaction(fn ->
        case Repo.fetch(__MODULE__, alias_tuple) do
          {:ok, %__MODULE__{}} -> {:error, :alias_in_use}
          {:error, :not_found} -> Repo.insert(%__MODULE__{alias_tuple: alias_tuple, room_id: room_id})
        end
      end)
    end
  end

  defp validate(alias) do
    case String.split(alias, ":", parts: 2) do
      ["#" <> localpart, server_name] ->
        cond do
          # TOIMPL: "The localpart of a room alias may contain any valid non-surrogate
          # Unicode codepoints except : and NUL."
          not String.valid?(localpart) -> {:error, :invalid_alias_localpart}
          server_name != RadioBeam.server_name() -> {:error, :invalid_or_unknown_server_name}
          :else -> :ok
        end

      _ ->
        {:error, :invalid_alias}
    end
  end

  def get_room_id(alias) do
    with {:ok, localpart, server_name} <- validate(alias),
         {:ok, %__MODULE__{room_id: room_id}} <- Repo.fetch(__MODULE__, {localpart, server_name}) do
      {:ok, room_id}
    end
  end
end
