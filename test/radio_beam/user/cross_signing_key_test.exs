defmodule RadioBeam.User.CrossSigningKeyTest do
  use ExUnit.Case, async: true

  alias RadioBeam.User.CrossSigningKey

  describe "parse/2" do
    test "parses a CrossSigningKey map as defined in the spec" do
      account = Fixtures.create_account()
      key_id = "1"
      {pubkey, _privkey} = :crypto.generate_key(:eddsa, :ed25519)

      params = %{
        "keys" => %{("ed25519:" <> key_id) => Base.encode64(pubkey, padding: false)},
        "usage" => ["master"],
        "user_id" => account.user_id
      }

      assert {:ok, %CrossSigningKey{} = csk} = CrossSigningKey.parse(params, account.user_id)
      assert "ed25519" = csk.algorithm
      assert ^key_id = csk.id
      assert ^pubkey = csk.key
      assert 0 = map_size(csk.signatures)
      assert ["master"] = csk.usages
    end

    test "errors with :malformed_key when the 'keys' field is malformed" do
      account = Fixtures.create_account()
      key_id = "1"
      {pubkey, _privkey} = :crypto.generate_key(:eddsa, :ed25519)

      params = %{
        "keys" => %{("e:d25519:" <> key_id) => Base.encode64(pubkey, padding: false)},
        "usage" => ["master"],
        "user_id" => account.user_id
      }

      assert {:error, :malformed_key} = CrossSigningKey.parse(params, account.user_id)

      params = %{
        "keys" => %{key_id => Base.encode64(pubkey, padding: false)},
        "usage" => ["master"],
        "user_id" => account.user_id
      }

      assert {:error, :malformed_key} = CrossSigningKey.parse(params, account.user_id)
    end

    test "errors with :too_many_keys or :no_key_provided when the 'keys' field has too many/no keys" do
      account = Fixtures.create_account()
      key_id = "1"
      {pubkey, _privkey} = :crypto.generate_key(:eddsa, :ed25519)

      params = %{
        "keys" => %{
          ("ed25519:" <> key_id) => Base.encode64(pubkey, padding: false),
          ("ed25519:" <> key_id <> "2") => Base.encode64(pubkey, padding: false)
        },
        "usage" => ["master"],
        "user_id" => account.user_id
      }

      assert {:error, :too_many_keys} = CrossSigningKey.parse(params, account.user_id)

      params = %{
        "keys" => %{},
        "usage" => ["master"],
        "user_id" => account.user_id
      }

      assert {:error, :no_key_provided} = CrossSigningKey.parse(params, account.user_id)
    end

    test "errors with :user_ids_do_not_match when the supplied device owner's ID does not match the one on the params" do
      account = Fixtures.create_account()
      key_id = "1"
      {pubkey, _privkey} = :crypto.generate_key(:eddsa, :ed25519)

      params = %{
        "keys" => %{("e:d25519:" <> key_id) => Base.encode64(pubkey, padding: false)},
        "usage" => ["master"],
        "user_id" => "@someone:random"
      }

      assert {:error, :user_ids_do_not_match} = CrossSigningKey.parse(params, account.user_id)
    end
  end
end
