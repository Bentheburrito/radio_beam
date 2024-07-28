defmodule RadioBeam.ErrorsTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Errors

  describe "standard errors" do
    test "MUST have `error` and `errcode` keys" do
      for std_err <- Errors.std_errors() do
        assert %{errcode: _, error: _} = apply(Errors, std_err, [])
      end
    end
  end

  describe "endpoint errors" do
    test "can handle atom errcodes" do
      assert %{errcode: "M_UNAUTHORIZED"} = Errors.endpoint_error(:unauthorized, "")
    end

    test "can handle string errcodes" do
      assert %{errcode: "M_UNAUTHORIZED"} = Errors.endpoint_error("M_UNAUTHORIZED", "")
    end

    test "returns an error message" do
      assert %{error: "You do not have access"} = Errors.endpoint_error("M_UNAUTHORIZED", "You do not have access")
    end
  end
end
