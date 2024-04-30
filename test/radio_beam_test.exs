defmodule RadioBeamTest do
  use ExUnit.Case

  describe "canonical_encode/1 correctly encodes" do
    test "an empty object" do
      assert {:ok, "{}"} = RadioBeam.canonical_encode(%{})
    end

    test "a simple object with already-ordered keys with different value types" do
      json =
        Jason.decode!("""
        {
            "one": 1,
            "two": "Two"
        }
        """)

      assert {:ok, ~s|{"one":1,"two":"Two"}|} = RadioBeam.canonical_encode(json)
    end

    test "a simple object with out-of-order keys" do
      json =
        Jason.decode!("""
        {
           "b": "2",
           "a": "1"
        }
        """)

      assert {:ok, ~s|{"a":"1","b":"2"}|} = RadioBeam.canonical_encode(json)
    end

    test "a complex object with many nested values" do
      json =
        Jason.decode!("""
        {
            "auth": {
                "success": true,
                "mxid": "@john.doe:example.com",
                "profile": {
                    "display_name": "John Doe",
                    "three_pids": [
                        {
                            "medium": "email",
                            "address": "john.doe@example.org"
                        },
                        {
                            "medium": "msisdn",
                            "address": "123456789"
                        }
                    ]
                }
            }
        }
        """)

      expected =
        ~s|{"auth":{"mxid":"@john.doe:example.com","profile":{"display_name":"John Doe","three_pids":[{"address":"john.doe@example.org","medium":"email"},{"address":"123456789","medium":"msisdn"}]},"success":true}}|

      assert {:ok, ^expected} = RadioBeam.canonical_encode(json)
    end

    test "a simple object with various unicode characters" do
      json =
        Jason.decode!("""
        {
            "a": "日本語"
        }
        """)

      assert {:ok, ~s|{"a":"日本語"}|} = RadioBeam.canonical_encode(json)
    end

    test "a simple object with kanji values" do
      json =
        Jason.decode!("""
        {
            "a": "日本語"
        }
        """)

      assert {:ok, ~s|{"a":"日本語"}|} = RadioBeam.canonical_encode(json)
    end

    test "a simple object with kanji keys" do
      json =
        Jason.decode!("""
        {
            "本": 2,
            "日": 1
        }
        """)

      assert {:ok, ~s|{"日":1,"本":2}|} = RadioBeam.canonical_encode(json)
    end

    test "a simple object with a unicode value" do
      json =
        Jason.decode!("""
        {
            "a": "\u65E5"
        }
        """)

      assert {:ok, ~s|{"a":"日"}|} = RadioBeam.canonical_encode(json)
    end

    test "a simple object with a null value" do
      json =
        Jason.decode!("""
        {
            "a": null
        }
        """)

      assert {:ok, ~s|{"a":null}|} = RadioBeam.canonical_encode(json)
    end

    test "a simple object with some weird ass values" do
      json =
        Jason.decode!("""
        {
            "a": -0,
            "b": 1e10
        }
        """)

      assert {:ok, ~s|{"a":0,"b":10000000000}|} = RadioBeam.canonical_encode(json)
    end
  end
end
