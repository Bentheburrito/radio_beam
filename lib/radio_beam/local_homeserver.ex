defmodule RadioBeam.LocalHomeserver do
  @moduledoc """
  Functions for managing local homeserver configuration
  """

  def new_config(%{"server_display_name" => display_name, "admin_localparts" => admin_localparts} = params) do
    host = Map.get(params, "delegated_host", display_name)

    with {:ok, display_name} <- validate_server_name(display_name),
         {:ok, host} <- validate_server_name(host) do
      admins = for localpart <- admin_localparts, do: "@#{localpart}:#{display_name}"

      {:ok,
       %{
         server_display_name: display_name,
         delegated_host: host,
         admins: admins
       }}
    end
  end

  defp validate_server_name(server_name) do
    case URI.new("placeholder://" <> server_name) do
      {:ok, %URI{host: host, port: nil}} -> {:ok, host}
      {:ok, %URI{host: host, port: port}} when is_integer(port) -> {:ok, "#{host}:#{port}"}
      {:ok, %URI{}} -> {:error, :invalid_server_name}
      error -> error
    end
  end
end
