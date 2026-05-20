defmodule RadioBeamWeb.AccountHTML do
  use RadioBeamWeb, :html

  embed_templates "account_html/*"

  @default_unit (Mix.env() == :test && :microsecond) || :millisecond
  def fmt_unix(unix, unit \\ @default_unit) when is_integer(unix) and unix >= 0 do
    unix |> DateTime.from_unix!(unit) |> Calendar.strftime("%B %d %Y @ %H:%M:%S")
  end

  def maybe_ip(nil), do: "N/A"
  def maybe_ip({_a, _b, _c, _d} = ip_tuple), do: RadioBeamWeb.Utils.ip_tuple_to_string(ip_tuple)
end
