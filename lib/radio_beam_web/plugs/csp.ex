defmodule RadioBeamWeb.Plugs.CSP do
  @moduledoc """
  Sets `Phoenix.Controller.put_secure_browser_headers`, including the
  `Content-Security-Policy` header, assigning `:asset_nonce` for use in
  `nonce=` attrs in elements.

  Credit to @peterhartman and @slouchpie on Elixir Forum:
  https://elixirforum.com/t/heroicon-defined-in-core-components-not-working/61182/26
  """
  def init(options), do: options

  def call(conn, _opts) do
    nonce = generate_nonce()
    csp_headers = header_value(nonce)

    conn
    |> Plug.Conn.assign(:asset_nonce, nonce)
    |> Phoenix.Controller.put_secure_browser_headers(%{"content-security-policy" => csp_headers})
  end

  defp generate_nonce(size \\ 10),
    do: size |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp header_value(nonce) do
    "default-src 'none'; script-src 'nonce-#{nonce}'; style-src 'nonce-#{nonce}'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; upgrade-insecure-requests"
  end
end
