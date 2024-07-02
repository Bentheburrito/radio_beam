defmodule RadioBeamWeb.ErrorJSON do
  alias RadioBeam.Errors

  # If you want to customize a particular status code,
  # you may add your own clauses, such as:
  #
  # def render("500.json", _assigns) do
  #   %{errors: %{detail: "Internal Server Error"}}
  # end

  # By default, Phoenix returns the status message from
  # the template name. For example, "404.json" becomes
  # "Not Found".
  def render("404.json", _assigns) do
    Errors.not_found(Phoenix.Controller.status_message_from_template("404.json"))
  end

  def render(template, _assigns) do
    Errors.unknown(Phoenix.Controller.status_message_from_template(template))
  end
end
