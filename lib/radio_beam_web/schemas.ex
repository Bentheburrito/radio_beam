defmodule RadioBeamWeb.Schemas do
  @moduledoc false

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

  @doc """
  Parses a string-ified integer. If given an int, it is simply returned in an
  :ok tuple. Returns {:error, :invalid} for all other inputs.

    iex> RadioBeamWeb.Schemas.as_integer("12")
    {:ok, 12}
    iex> RadioBeamWeb.Schemas.as_integer(12)
    {:ok, 12}
    iex> RadioBeamWeb.Schemas.as_integer("12a")
    {:error, :invalid}
    iex> RadioBeamWeb.Schemas.as_integer("one")
    {:error, :invalid}
  """
  @spec as_integer(String.t() | integer()) :: {:ok, integer()} | {:error, :invalid}
  def as_integer(int) when is_integer(int), do: {:ok, int}

  def as_integer(value) do
    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      {_number, _non_empty_binary} -> {:error, :invalid}
      :error -> {:error, :invalid}
    end
  end
end
