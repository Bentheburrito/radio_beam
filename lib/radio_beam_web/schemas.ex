defmodule RadioBeamWeb.Schemas do
  alias Polyjuice.Util.Schema

  def user_id(value) do
    with {:ok, _} <- Schema.user_id(value) do
      {:ok, value}
    end
  end

  def room_id(value) do
    with {:ok, _} <- Schema.room_id(value) do
      {:ok, value}
    end
  end

  def as_integer(value) do
    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      {_number, _non_empty_binary} -> {:error, :invalid}
      :error -> {:error, :invalid}
    end
  end
end
