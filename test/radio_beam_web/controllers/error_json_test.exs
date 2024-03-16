defmodule RadioBeamWeb.ErrorJSONTest do
  use RadioBeamWeb.ConnCase, async: true

  test "renders 404" do
    assert RadioBeamWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert RadioBeamWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
