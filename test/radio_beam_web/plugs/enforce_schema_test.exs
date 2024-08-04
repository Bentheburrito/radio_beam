defmodule RadioBeamWeb.Plugs.EnforceSchemaTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias Polyjuice.Util.Schema
  alias RadioBeamWeb.Plugs.EnforceSchema

  describe "call/2" do
    test "parses a compliant request" do
      req = %{
        "name" => "Jim",
        "age" => 42,
        "email" => "jhalpert@dundermifflin.net"
      }

      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint", req)
        |> EnforceSchema.call(mod: __MODULE__)

      assert %{request: %{"name" => "Jim", "email" => "jhalpert@dundermifflin.net", "role" => "user"}} = conn.assigns
    end

    test "rejects a request with a missing required param" do
      req = %{
        "age" => 42,
        "email" => "rando@google.com"
      }

      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint", req)
        |> EnforceSchema.call(mod: __MODULE__)

      assert {400, _headers, body} = sent_resp(conn)
      assert body =~ "M_BAD_JSON"
      assert body =~ "is required but is not present"
    end

    test "rejects a request with a param that has the wrong type" do
      req = %{
        "name" => "Jerry",
        "age" => "42",
        "email" => "rando@google.com"
      }

      conn =
        :post
        |> conn("/_matrix/v3/some_endpoint", req)
        |> EnforceSchema.call(mod: __MODULE__)

      assert {400, _headers, body} = sent_resp(conn)
      assert body =~ "M_BAD_JSON"
      assert body =~ "needs to be a(n) integer"
    end
  end

  def schema do
    %{
      "name" => :string,
      "age" => :integer,
      "email" => [:string, :optional],
      "role" => [Schema.enum(["admin", "moderator", "user"]), default: "user"]
    }
  end
end
