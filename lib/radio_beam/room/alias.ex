defmodule RadioBeam.RoomAlias do
  @moduledoc """
  This table maps room aliases to room IDs
  """
  @types [alias: :string, room_id: :string]
  @attrs Keyword.keys(@types)

  use Memento.Table,
    attributes: @attrs,
    type: :set

  @type t() :: %__MODULE__{}

  # TOIMPL: check the room alias grammar. Upstream polyjuice_util to check for < 255 byte limit + localpart validation
  def put(room_alias, room_id) do
    case {Memento.Query.read(__MODULE__, room_alias), Memento.Query.read(RadioBeam.Room, room_id)} do
      {_, nil} ->
        {:error, :room_does_not_exist}

      {%__MODULE__{}, _} ->
        {:error, :alias_in_use}

      {nil, %RadioBeam.Room{id: ^room_id}} ->
        Memento.Query.write(%__MODULE__{alias: room_alias, room_id: room_id})
    end
  end

  def to_room_id(room_alias) do
    case Memento.transaction(fn -> Memento.Query.read(__MODULE__, room_alias) end) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, %__MODULE__{room_id: room_id}} -> {:ok, room_id}
    end
  end
end
