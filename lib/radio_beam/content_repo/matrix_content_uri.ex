defmodule RadioBeam.ContentRepo.MatrixContentURI do
  @attrs ~w|id server_name|a
  @enforce_keys @attrs
  defstruct @attrs

  def new(server_name \\ RadioBeam.server_name(), id \\ Ecto.UUID.generate()) do
    with :ok <- validate_character_set(server_name, :invalid_server_name),
         :ok <- validate_character_set(id, :invalid_media_id) do
      {:ok, %__MODULE__{id: id, server_name: server_name}}
    end
  end

  def parse("mxc://" <> _ = uri_string) do
    with %URI{scheme: "mxc", host: server_name, path: "/" <> id} <- URI.parse(uri_string) do
      new(server_name, id)
    end
  end

  def parse(_uri_string) do
    {:error, :invalid_scheme}
  end

  @valid_regex ~r/^[A-Za-z0-9\-_]*$/
  defp validate_character_set(string, error_reason) when is_binary(string) do
    if Regex.match?(@valid_regex, string), do: :ok, else: {:error, error_reason}
  end

  defimpl String.Chars do
    def to_string(mxc), do: "mxc://#{mxc.server_name}/#{mxc.id}"
  end

  defimpl Jason.Encoder do
    def encode(mxc, opts), do: mxc |> to_string() |> Jason.Encoder.encode(opts)
  end
end
