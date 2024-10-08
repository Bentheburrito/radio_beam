defmodule RadioBeam.ContentRepo.MatrixContentURITest do
  use ExUnit.Case, async: true

  alias RadioBeam.ContentRepo.MatrixContentURI

  describe "new/2" do
    test "creates a mxc struct from valid input" do
      assert {:ok, %MatrixContentURI{id: "abcd_-123", server_name: "local-host"}} =
               MatrixContentURI.new("local-host", "abcd_-123")

      assert {:ok,
              %MatrixContentURI{
                id: "1234567890qwertyuiopasdfghjklzxcvbnmQWERTYUIOPASDFGHJKLZXCVBNM",
                server_name: "some-mx-homeserver.dev"
              }} =
               MatrixContentURI.new(
                 "some-mx-homeserver.dev",
                 "1234567890qwertyuiopasdfghjklzxcvbnmQWERTYUIOPASDFGHJKLZXCVBNM"
               )
    end

    test "errors when given an invalid server_name" do
      assert {:error, :invalid_server_name} = MatrixContentURI.new("local.host/.././yo", "abcde")
      assert {:error, :invalid_server_name} = MatrixContentURI.new(".././localhost", "whoa_there")
      assert {:error, :invalid_server_name} = MatrixContentURI.new("~/localhost", "sus")
    end

    test "errors when given an invalid id" do
      assert {:error, :invalid_media_id} = MatrixContentURI.new("localhost", "@abcde")
      assert {:error, :invalid_media_id} = MatrixContentURI.new("localhost", ".././whoa_there")
      assert {:error, :invalid_media_id} = MatrixContentURI.new("localhost", "~/sus")
    end
  end

  describe "parse/1" do
    test "parses a valid MXC URI" do
      assert {:ok, %MatrixContentURI{id: "abcd", server_name: "localhost"}} =
               MatrixContentURI.parse("mxc://localhost/abcd")
    end

    test "errors when given an invalid MXC URI" do
      assert {:error, :invalid_scheme} = MatrixContentURI.parse("mxc:/localhost/abcd")
      assert {:error, :invalid_server_name} = MatrixContentURI.parse("mxc://local+host/abcd")
      assert {:error, :invalid_media_id} = MatrixContentURI.parse("mxc://localhost/ab.cd")
    end
  end

  describe "to_string/1" do
    test "converts a MatrixContentURI struct to its string representation" do
      {:ok, mxc} = MatrixContentURI.new("localhost", "helloworld")
      assert "mxc://localhost/helloworld" = to_string(mxc)
    end
  end
end
