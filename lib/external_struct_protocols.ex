defimpl JSON.Encoder, for: URI do
  def encode(uri, encoder) do
    uri
    |> to_string()
    |> JSON.Encoder.BitString.encode(encoder)
  end
end
