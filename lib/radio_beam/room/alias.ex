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
    Repo.one_shot(fn ->
      case {Memento.Query.read(__MODULE__, room_alias), Room.get(room_id)} do
        {_, {:error, :not_found}} ->
          {:error, :room_does_not_exist}

        {%__MODULE__{}, _} ->
          {:error, :alias_in_use}

        {nil, {:ok, %RadioBeam.Room{id: ^room_id}}} ->
          {:ok, Memento.Query.write(%__MODULE__{alias: room_alias, room_id: room_id})}
      end
    end)
  end

  def get_room_id(room_alias) do
    Repo.one_shot(fn ->
      case Memento.Query.read(__MODULE__, room_alias) do
        nil -> {:error, :not_found}
        %__MODULE__{room_id: room_id} -> {:ok, room_id}
      end
    end)
  end
end
