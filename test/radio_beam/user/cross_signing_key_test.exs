defmodule RadioBeam.User.CrossSigningKeyTest do
  use ExUnit.Case, async: true

  alias RadioBeam.User.CrossSigningKey

  describe "parse/2" do
    test "parses a CrossSigningKey map as defined in the spec" do
      user = Fixtures.user()
      key_id = "1"
      {pubkey, _privkey} = :crypto.generate_key(:eddsa, :ed25519)

      params = %{
        "keys" => %{("ed25519:" <> key_id) => Base.encode64(pubkey, padding: false)},
        "usage" => ["master"],
        "user_id" => user.id
      }

      assert {:ok, %CrossSigningKey{} = csk} = CrossSigningKey.parse(params, user.id)
      assert "ed25519" = csk.algorithm
      assert ^key_id = csk.id
      assert ^pubkey = csk.key
      assert :none = csk.signatures
      assert ["master"] = csk.usages
    end

    test "errors with :malformed_key when the 'keys' field is malformed" do
      user = Fixtures.user()
      key_id = "1"
      {pubkey, _privkey} = :crypto.generate_key(:eddsa, :ed25519)

      params = %{
        "keys" => %{("e:d25519:" <> key_id) => Base.encode64(pubkey, padding: false)},
        "usage" => ["master"],
        "user_id" => user.id
      }

      assert {:error, :malformed_key} = CrossSigningKey.parse(params, user.id)

      params = %{
        "keys" => %{key_id => Base.encode64(pubkey, padding: false)},
        "usage" => ["master"],
        "user_id" => user.id
      }

      assert {:error, :malformed_key} = CrossSigningKey.parse(params, user.id)
    end

    test "errors with :too_many_keys or :no_key_provided when the 'keys' field has too many/no keys" do
      user = Fixtures.user()
      key_id = "1"
      {pubkey, _privkey} = :crypto.generate_key(:eddsa, :ed25519)

      params = %{
        "keys" => %{
          ("ed25519:" <> key_id) => Base.encode64(pubkey, padding: false),
          ("ed25519:" <> key_id <> "2") => Base.encode64(pubkey, padding: false)
        },
        "usage" => ["master"],
        "user_id" => user.id
      }

      assert {:error, :too_many_keys} = CrossSigningKey.parse(params, user.id)

      params = %{
        "keys" => %{},
        "usage" => ["master"],
        "user_id" => user.id
      }

      assert {:error, :no_key_provided} = CrossSigningKey.parse(params, user.id)
    end

    test "errors with :user_ids_do_not_match when the supplied device owner's ID does not match the one on the params" do
      user = Fixtures.user()
      key_id = "1"
      {pubkey, _privkey} = :crypto.generate_key(:eddsa, :ed25519)

      params = %{
        "keys" => %{("e:d25519:" <> key_id) => Base.encode64(pubkey, padding: false)},
        "usage" => ["master"],
        "user_id" => "@someone:random"
      }

      assert {:error, :user_ids_do_not_match} = CrossSigningKey.parse(params, user.id)
    end
  end
end
