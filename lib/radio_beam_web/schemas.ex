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
end
