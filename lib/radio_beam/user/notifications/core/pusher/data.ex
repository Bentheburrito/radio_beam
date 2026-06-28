defmodule RadioBeam.User.Notifications.Core.Pusher.Data do
  @moduledoc """
  Parsed
  [PusherData](https://spec.matrix.org/latest/client-server-api/#client-behaviour-12)
  object defined by the spec.
  """

  defstruct ~w|kind required extra|a

  @opaque t() :: %__MODULE__{kind: :http | :email, required: %{required(:url) => URI.t()} | %{}, extra: map()}

  def new("http", %{"url" => url} = payload) do
    with {:ok, uri} <- validate_url(url) do
      {:ok, %__MODULE__{kind: :http, required: %{url: uri}, extra: Map.delete(payload, "url")}}
    end
  end

  def new("http", _payload), do: {:error, :missing_url}
  def new("email", payload), do: {:ok, %__MODULE__{kind: :email, required: %{}, extra: payload}}
  def new(_unsupported, _payload), do: {:error, :unsupported_kind}

  defp validate_url(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", path: "/_matrix/push/v1/notify", host: host} = uri} when byte_size(host) > 0 ->
        {:ok, uri}

      _error_or_invalid ->
        {:error, :url}
    end
  end

  def kind(%__MODULE__{} = pusher_data), do: pusher_data.kind
  def required_fields(%__MODULE__{} = pusher_data), do: pusher_data.required

  defimpl JSON.Encoder do
    def encode(data, encoder), do: data.required |> Map.merge(data.extra) |> JSON.Encoder.Map.encode(encoder)
  end
end
