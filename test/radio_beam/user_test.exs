defmodule RadioBeam.UserTest do
  use ExUnit.Case

  alias RadioBeam.User

  describe "new/1" do
    @password "Ar3allyg00dpwd!@#$"
    test "can create a new user from params with a valid user ID" do
      valid_ids = [
        "@hello:world",
        "@greetings_sir123:inter.net",
        "@_xcoolguy9x_:servername",
        "@+=-_/somehowvalid:ok.com",
        "@snowful:matrix.org"
      ]

      for id <- valid_ids, do: assert({:ok, %User{id: ^id}} = User.new(id, @password))
    end

    test "will not create users with invalid user IDs" do
      invalid_ids = [
        "hello:world",
        "@:servername",
        "@Hello:world",
        "@hi!there:inter.net",
        "@hello :world",
        super_long_user_id()
      ]

      for id <- invalid_ids, do: assert({:error, _} = User.new(id, @password))
    end
  end

  defp super_long_user_id do
    "@behold_a_bunch_of_underscores_to_get_over_255_chars#{String.duplicate("_", 193)}:servername"
  end
end
