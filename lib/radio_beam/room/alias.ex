defmodule RadioBeam.Room.Alias do
  @moduledoc """
  This table maps room aliases to room IDs
  """
  @types [alias: :string, room_id: :string]
  @attrs Keyword.keys(@types)

  use Memento.Table,
    attributes: @attrs,
    type: :set

  alias RadioBeam.Room
  alias RadioBeam.Repo

  @type t() :: %__MODULE__{}

  # TOIMPL: check the room alias grammar
  @doc """
  Adds a new room alias mapping. Returns `{:ok, %Alias{}}` on success, or
  `{:error, error}` otherwise, where `error` is either `:room_does_not_exist` or
  `:alias_in_use`.
  """
  def put(room_alias, room_id) do
    Repo.transaction(fn ->
      case {Repo.fetch(__MODULE__, room_alias), Repo.fetch(Room, room_id)} do
        {_, {:error, :not_found}} ->
          {:error, :room_does_not_exist}

        {{:ok, %__MODULE__{}}, _} ->
          {:error, :alias_in_use}

        {{:error, :not_found}, {:ok, %RadioBeam.Room{id: ^room_id}}} ->
          Repo.insert(%__MODULE__{alias: room_alias, room_id: room_id})
      end
    end)
  end

  def get_room_id(room_alias) do
    with {:ok, %__MODULE__{room_id: room_id}} <- Repo.fetch(__MODULE__, room_alias) do
      {:ok, room_id}
    end
  end
end
