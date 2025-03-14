defmodule RadioBeam.User.Device.OneTimeKeyRingTest do
  use ExUnit.Case, async: true

  alias RadioBeam.User.Device.OneTimeKeyRing

  setup do
    {user, device} = Fixtures.device(Fixtures.user())
    %{user: user, device: device}
  end

  @otk_keys %{
    "signed_curve25519:AAAAHQ" => %{
      "key" => "key1",
      "signatures" => %{
        "@alice:example.com" => %{
          "ed25519:JLAFKJWSCS" =>
            "IQeCEPb9HFk217cU9kw9EOiusC6kMIkoIRnbnfOh5Oc63S1ghgyjShBGpu34blQomoalCyXWyhaaT3MrLZYQAA"
        }
      }
    },
    "signed_curve25519:AAAAHg" => %{
      "key" => "key2",
      "signatures" => %{
        "@alice:example.com" => %{
          "ed25519:JLAFKJWSCS" =>
            "FLWxXqGbwrb8SM3Y795eB6OA8bwBcoMZFXBqnTn58AYWZSqiD45tlBVcDa2L7RwdKXebW/VzDlnfVJ+9jok1Bw"
        }
      }
    }
  }

  describe "put_otks/2" do
    test "puts one time keys on the key ring", %{device: device} do
      otk_ring = OneTimeKeyRing.put_otks(device.one_time_key_ring, @otk_keys)
      assert %{"signed_curve25519" => [%{"id" => "AAAAHQ"}, _]} = otk_ring.one_time_keys
    end

    test "adds newer keys to the end (such that older keys will be claimed first)", %{device: device} do
      other_keys =
        Map.new(@otk_keys, fn {_, content} -> {"signed_curve25519:#{Fixtures.random_string(6)}", content} end)

      otk_ring = OneTimeKeyRing.put_otks(device.one_time_key_ring, @otk_keys)
      otk_ring = OneTimeKeyRing.put_otks(otk_ring, other_keys)
      %{"signed_curve25519" => [old1, old2, new1, new2]} = otk_ring.one_time_keys

      assert ("signed_curve25519:" <> old1["id"]) in Map.keys(@otk_keys)
      assert ("signed_curve25519:" <> old2["id"]) in Map.keys(@otk_keys)
      assert ("signed_curve25519:" <> new1["id"]) in Map.keys(other_keys)
      assert ("signed_curve25519:" <> new2["id"]) in Map.keys(other_keys)
    end
  end

  @fallback_key %{
    "signed_curve25519:AAAAGj" => %{
      "fallback" => true,
      "key" => "fallback1",
      "signatures" => %{
        "@alice:example.com" => %{
          "ed25519:JLAFKJWSCS" =>
            "FLWxXqGbwrb8SM3Y795eB6OA8bwBcoMZFXBqnTn58AYWZSqiD45tlBVcDa2L7RwdKXebW/VzDlnfVJ+9jok1Bw"
        }
      }
    }
  }

  describe "put_fallback_keys/2" do
    test "puts a fallback key on the key ring", %{device: device} do
      otk_ring = OneTimeKeyRing.put_fallback_keys(device.one_time_key_ring, @fallback_key)
      assert %{"signed_curve25519" => %{"key" => "fallback1"}} = otk_ring.fallback_keys
    end

    test "overwrites a key an older key if it shares the same algorithm", %{device: device} do
      otk_ring = OneTimeKeyRing.put_fallback_keys(device.one_time_key_ring, @fallback_key)

      otk_ring =
        OneTimeKeyRing.put_fallback_keys(otk_ring, put_in(@fallback_key, ~w|signed_curve25519:AAAAGj key|, "fallback2"))

      assert %{"signed_curve25519" => %{"key" => "fallback2"}} = otk_ring.fallback_keys
    end
  end

  describe "claim_otk/2" do
    test "pops the first otk in the list under the given algorithm", %{device: device} do
      assert {:error, :not_found} = OneTimeKeyRing.claim_otk(device.one_time_key_ring, "signed_curve25519")

      otk_ring = OneTimeKeyRing.put_otks(device.one_time_key_ring, @otk_keys)

      assert {:ok, {%{"key" => "key1"}, otk_ring}} = OneTimeKeyRing.claim_otk(otk_ring, "signed_curve25519")
      assert {:ok, {%{"key" => "key2"}, otk_ring}} = OneTimeKeyRing.claim_otk(otk_ring, "signed_curve25519")
      assert {:error, :not_found} = OneTimeKeyRing.claim_otk(otk_ring, "signed_curve25519")
    end

    test "uses the fallback key when all one time keys have been exhausted", %{device: device} do
      assert {:error, :not_found} = OneTimeKeyRing.claim_otk(device.one_time_key_ring, "signed_curve25519")

      otk_ring = OneTimeKeyRing.put_otks(device.one_time_key_ring, @otk_keys)
      otk_ring = OneTimeKeyRing.put_fallback_keys(otk_ring, @fallback_key)

      refute get_in(otk_ring.fallback_keys["signed_curve25519"]["used?"])

      assert {:ok, {%{"key" => "key1"}, otk_ring}} = OneTimeKeyRing.claim_otk(otk_ring, "signed_curve25519")
      refute get_in(otk_ring.fallback_keys["signed_curve25519"]["used?"])

      assert {:ok, {%{"key" => "key2"}, otk_ring}} = OneTimeKeyRing.claim_otk(otk_ring, "signed_curve25519")
      refute get_in(otk_ring.fallback_keys["signed_curve25519"]["used?"])

      assert {:ok, {%{"key" => "fallback1"}, otk_ring}} = OneTimeKeyRing.claim_otk(otk_ring, "signed_curve25519")
      assert get_in(otk_ring.fallback_keys["signed_curve25519"]["used?"])

      assert {:ok, {%{"key" => "fallback1"}, otk_ring}} = OneTimeKeyRing.claim_otk(otk_ring, "signed_curve25519")
      assert get_in(otk_ring.fallback_keys["signed_curve25519"]["used?"])
    end
  end
end
