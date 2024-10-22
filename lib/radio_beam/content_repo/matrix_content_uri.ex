defmodule RadioBeam.ContentRepo.MatrixContentURI do
  @moduledoc """
  A struct representing an `mxc://` URI as defined in the C-S spec.
  """
  alias Polyjuice.Util.Identifiers.V1.ServerName

  @attrs ~w|id server_name|a
  @enforce_keys @attrs
  defstruct @attrs

  @type t() :: %__MODULE__{id: String.t(), server_name: String.t()}

  def new(server_name \\ RadioBeam.server_name(), id \\ Ecto.UUID.generate()) do
    with :ok <- validate_server_name(server_name),
         :ok <- validate_media_id(id) do
      {:ok, %__MODULE__{id: id, server_name: server_name}}
    end
  end

  def new!(server_name \\ RadioBeam.server_name(), id \\ Ecto.UUID.generate()) do
    case new(server_name, id) do
      {:ok, mxc} -> mxc
      {:error, error} -> raise to_string(error)
    end
  end

  def parse("mxc://" <> _ = uri_string) do
    with %URI{scheme: "mxc", host: server_name, path: "/" <> id} <- URI.parse(uri_string) do
      new(server_name, id)
    end
  end

  def parse(_uri_string), do: {:error, :invalid_scheme}

  @media_id_regex ~r/^[A-Za-z0-9\-_]*$/
  defp validate_media_id(media_id) when is_binary(media_id) do
    if Regex.match?(@media_id_regex, media_id), do: :ok, else: {:error, :invalid_media_id}
  end

  defp validate_server_name(server_name) when is_binary(server_name) do
    with {:ok, _} <- ServerName.parse(server_name), do: :ok
  end

  defimpl String.Chars do
    def to_string(mxc), do: "mxc://#{mxc.server_name}/#{mxc.id}"
  end

  defimpl Jason.Encoder do
    def encode(mxc, opts), do: mxc |> to_string() |> Jason.Encoder.encode(opts)
  end
end
