defmodule RadioBeamWeb.ErrorJSONTest do
  use RadioBeamWeb.ConnCase, async: true

  test "renders 404" do
    assert %{error: "Not Found"} = RadioBeamWeb.ErrorJSON.render("404.json", %{})
  end

  test "renders 500" do
    assert %{error: "Internal Server Error"} = RadioBeamWeb.ErrorJSON.render("500.json", %{})
  end
end
