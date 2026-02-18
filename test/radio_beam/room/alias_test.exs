defmodule RadioBeam.Room.AliasTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room.Alias

  describe "put/2" do
    test "creates an Alias given a valid room alias string" do
      valid_localparts = ~w|hello.world nottaken asjdf; %@#*I&SF&ED-gibberish|

      valid_server_names =
        ~w|localhost some.website.org hello-world.com 123.org my.matrixhs.co.uk [::1] 179.11.0.2|

      ports = [":3456", ""]

      for localpart <- valid_localparts, server_name <- valid_server_names, port <- ports do
        server_name = "#{server_name}#{port}"
        alias = "##{localpart}:#{server_name}"

        assert {:ok, %Alias{localpart: ^localpart, server_name: ^server_name}} = Alias.new(alias)
      end
    end

    test "errors with :invalid_alias when string is nonsensical" do
      for alias <- ["", "asdf", ";"] do
        assert {:error, :invalid_alias} = Alias.new(alias)
      end
    end

    test "errors with :invalid_alias_localpart when localpart contains null byte" do
      invalid_alias_localpart = <<"helloworld", 0>>
      alias = "##{invalid_alias_localpart}:localhost"
      assert {:error, :invalid_alias_localpart} = Alias.new(alias)
    end

    test "errors with :invalid_server_name when server_name is invalid" do
      alias_localpart = "helloowrld"

      invalid_server_names =
        ~w|localhost:asdf localhost:6432:346 localhost:6543:asdf loca/host matrix$.org Wow!.com|

      for server_name <- invalid_server_names do
        alias = "##{alias_localpart}:#{server_name}"
        assert {:error, :invalid_server_name} = Alias.new(alias)
      end
    end
  end

  describe "String.Chars impl" do
    test "converts an %Alias{} to a string as expected" do
      alias_str = "#some_alias:localhost"
      {:ok, alias} = Alias.new(alias_str)
      assert ^alias_str = to_string(alias)
    end
  end
end
