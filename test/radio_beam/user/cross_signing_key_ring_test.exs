defmodule RadioBeam.User.CrossSigningKeyRingTest do
  use ExUnit.Case, async: true

  alias RadioBeam.User.CrossSigningKeyRing

  describe "put/2" do
    setup do
      {user, device} = Fixtures.device(Fixtures.user())
      %{user: user, device: device}
    end

    test "adds the given master_key to the device", %{user: user, device: device} do
      {:ok, user} =
        CrossSigningKeyRing.put(user.id,
          master_key: %{
            "keys" => %{"ed25519:base64+master+public+key" => "base64+master+public+key"},
            "usage" => ["master"],
            "user_id" => user.id
          }
        )

      assert Base.decode64!("base64+master+public+key") == user.cross_signing_key_ring.master.key
      assert "ed25519" = user.cross_signing_key_ring.master.algorithm
    end

    test "errors if the user ID on the key doesn't match the device's owner", %{user: user, device: device} do
      assert {:error, :user_ids_do_not_match} =
               CrossSigningKeyRing.put(user.id,
                 master_key: %{
                   "keys" => %{"ed25519:base64+master+public+key" => "base64+master+public+key"},
                   "usage" => ["master"],
                   "user_id" => "@alice:example.com"
                 }
               )
    end

    test "adds all the given cross-signing keys to the device, as long as the user/self keys were signed by the master key",
         %{user: user, device: device} do
      master_key_id = "base64masterpublickey"
      {master_pubkey, master_privkey} = :crypto.generate_key(:eddsa, :ed25519)

      master_key = %{
        "keys" => %{("ed25519:" <> master_key_id) => Base.encode64(master_pubkey, padding: false)},
        "usage" => ["master"],
        "user_id" => user.id
      }

      master_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(master_privkey, padding: false), master_key_id)

      {:ok, self_signing_key} =
        Polyjuice.Util.JSON.sign(
          %{
            "keys" => %{
              "ed25519:base64selfsigningpublickey" =>
                Base.encode64("base64+self+signing+master+public+key", padding: false)
            },
            "usage" => ["self_signing"],
            "user_id" => user.id
          },
          user.id,
          master_signingkey
        )

      {:ok, user_signing_key} =
        Polyjuice.Util.JSON.sign(
          %{
            "keys" => %{
              "ed25519:base64usersigningpublickey" =>
                Base.encode64("base64+user+signing+master+public+key", padding: false)
            },
            "usage" => ["user_signing"],
            "user_id" => user.id
          },
          user.id,
          master_signingkey
        )

      {:ok, user} =
        CrossSigningKeyRing.put(user.id,
          master_key: master_key,
          self_signing_key: self_signing_key,
          user_signing_key: user_signing_key
        )

      assert ^master_pubkey = user.cross_signing_key_ring.master.key
      assert "ed25519" = user.cross_signing_key_ring.master.algorithm
    end

    test "errors with :missing_master_key when trying to put a self-/user-signing key without previously supplying a master key",
         %{user: user, device: device} do
      master_key_id = "base64masterpublickey"
      {_master_pubkey, master_privkey} = :crypto.generate_key(:eddsa, :ed25519)

      master_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(master_privkey, padding: false), master_key_id)

      {:ok, self_signing_key} =
        Polyjuice.Util.JSON.sign(
          %{
            "keys" => %{
              "ed25519:base64selfsigningpublickey" =>
                Base.encode64("base64+self+signing+master+public+key", padding: false)
            },
            "usage" => ["self_signing"],
            "user_id" => user.id
          },
          user.id,
          master_signingkey
        )

      {:ok, user_signing_key} =
        Polyjuice.Util.JSON.sign(
          %{
            "keys" => %{
              "ed25519:base64usersigningpublickey" =>
                Base.encode64("base64+user+signing+master+public+key", padding: false)
            },
            "usage" => ["user_signing"],
            "user_id" => user.id
          },
          user.id,
          master_signingkey
        )

      {:error, :missing_master_key} =
        CrossSigningKeyRing.put(user.id, self_signing_key: self_signing_key)

      {:error, :missing_master_key} =
        CrossSigningKeyRing.put(user.id, user_signing_key: user_signing_key)
    end

    test "errors with :missing_or_invalid_master_key_signatures when a signature is missing on the self/user keys",
         %{user: user, device: device} do
      master_key_id = "base64masterpublickey"
      {master_pubkey, _master_privkey} = :crypto.generate_key(:eddsa, :ed25519)

      master_key = %{
        "keys" => %{("ed25519:" <> master_key_id) => Base.encode64(master_pubkey, padding: false)},
        "usage" => ["master"],
        "user_id" => user.id
      }

      self_signing_key =
        %{
          "keys" => %{
            "ed25519:base64selfsigningpublickey" =>
              Base.encode64("base64+self+signing+master+public+key", padding: false)
          },
          "usage" => ["self_signing"],
          "user_id" => user.id
        }

      user_signing_key =
        %{
          "keys" => %{
            "ed25519:base64usersigningpublickey" =>
              Base.encode64("base64+user+signing+master+public+key", padding: false)
          },
          "usage" => ["user_signing"],
          "user_id" => user.id
        }

      {:error, :missing_or_invalid_master_key_signatures} =
        CrossSigningKeyRing.put(user.id,
          master_key: master_key,
          self_signing_key: self_signing_key
        )

      {:error, :missing_or_invalid_master_key_signatures} =
        CrossSigningKeyRing.put(user.id,
          master_key: master_key,
          user_signing_key: user_signing_key
        )
    end

    test "errors with :missing_or_invalid_master_key_signatures when a bad signature is on the self/user keys",
         %{user: user, device: device} do
      master_key_id = "base64masterpublickey"
      {_master_pubkey, master_privkey} = :crypto.generate_key(:eddsa, :ed25519)
      {master_pubkey, _master_privkey} = :crypto.generate_key(:eddsa, :ed25519)

      master_key = %{
        "keys" => %{("ed25519:" <> master_key_id) => Base.encode64(master_pubkey, padding: false)},
        "usage" => ["master"],
        "user_id" => user.id
      }

      master_signingkey =
        Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(master_privkey, padding: false), master_key_id)

      {:ok, self_signing_key} =
        Polyjuice.Util.JSON.sign(
          %{
            "keys" => %{
              "ed25519:base64selfsigningpublickey" =>
                Base.encode64("base64+self+signing+master+public+key", padding: false)
            },
            "usage" => ["self_signing"],
            "user_id" => user.id
          },
          user.id,
          master_signingkey
        )

      {:ok, user_signing_key} =
        Polyjuice.Util.JSON.sign(
          %{
            "keys" => %{
              "ed25519:base64usersigningpublickey" =>
                Base.encode64("base64+user+signing+master+public+key", padding: false)
            },
            "usage" => ["user_signing"],
            "user_id" => user.id
          },
          user.id,
          master_signingkey
        )

      {:error, :missing_or_invalid_master_key_signatures} =
        CrossSigningKeyRing.put(user.id,
          master_key: master_key,
          self_signing_key: self_signing_key
        )

      {:error, :missing_or_invalid_master_key_signatures} =
        CrossSigningKeyRing.put(user.id,
          master_key: master_key,
          user_signing_key: user_signing_key
        )
    end
  end
end
