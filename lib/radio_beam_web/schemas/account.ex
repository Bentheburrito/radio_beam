defmodule RadioBeamWeb.Schemas.Account do
  @moduledoc false

  def put_tag, do: %{"order" => [&order/1, default: 1.0]}

  defp order(value) do
    if is_number(value) and value > 0 and value < 1 do
      {:ok, value}
    else
      {:error, :invalid_order}
    end
  end
end
