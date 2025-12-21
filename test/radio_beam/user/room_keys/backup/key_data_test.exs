defmodule RadioBeam.User.RoomKeys.Backup.KeyDataTest do
  use ExUnit.Case, async: true

  alias RadioBeam.User.RoomKeys.Backup.KeyData

  describe "compare/2" do
    test "correctly compares two KeyData structs" do
      kd1 =
        KeyData.new!(%{
          "first_message_index" => 1,
          "forwarded_count" => 1,
          "session_data" => %{},
          "is_verified" => true
        })

      assert :eq == KeyData.compare(kd1, kd1)

      for verified? <- ~w|true false|a,
          fmi <- 0..2,
          fc <- 0..2,
          sd <- [%{"a" => 1}, %{"b" => 0}],
          {fmi, fc} != {1, 1} do
        expected =
          case verified? do
            false ->
              :lt

            true ->
              case fmi do
                0 ->
                  :gt

                2 ->
                  :lt

                1 ->
                  case fc do
                    0 -> :gt
                    2 -> :lt
                  end
              end
          end

        kd2 =
          KeyData.new!(%{
            "first_message_index" => fmi,
            "forwarded_count" => fc,
            "session_data" => sd,
            "is_verified" => verified?
          })

        assert expected == KeyData.compare(kd1, kd2)
      end
    end
  end
end
