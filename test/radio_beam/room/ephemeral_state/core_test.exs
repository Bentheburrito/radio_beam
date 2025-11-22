defmodule RadioBeam.Room.EphemeralState.CoreTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room.EphemeralState.Core

  describe "put_typing/3" do
    test "puts users as typing and starts timers to clear the status" do
      state = Core.new!()
      assert 0 = map_size(state.actively_typing)

      state = Core.put_typing(state, "@hi:localhost", 15)
      assert 1 = map_size(state.actively_typing)

      state = Core.put_typing(state, "@yo:localhost", Core.max_timeout_ms() + 5)
      assert 2 = map_size(state.actively_typing)

      assert_receive {:delete_typing, "@hi:localhost"}, 40
    end
  end

  describe "all_typing/1" do
    test "returns all actively typing user IDs" do
      state = Core.new!()
      assert [] = Core.all_typing(state)

      state = Core.put_typing(state, "@hi:localhost", 5000)
      assert ["@hi:localhost"] = Core.all_typing(state)

      state = Core.put_typing(state, "@yo:localhost", 5000)
      assert ["@hi:localhost", "@yo:localhost"] = Core.all_typing(state)
    end
  end

  describe "delete_typing/2" do
    test "removes a user ID from the actively typing list" do
      state =
        Core.new!() |> Core.put_typing("@hi:localhost", 5000) |> Core.put_typing("@yo:localhost", 5000)

      assert ["@hi:localhost", "@yo:localhost"] = Core.all_typing(state)

      state = Core.delete_typing(state, "@yo:localhost")
      assert ["@hi:localhost"] = Core.all_typing(state)

      state = Core.delete_typing(state, "asdfasdf")
      assert ["@hi:localhost"] = Core.all_typing(state)

      state = Core.delete_typing(state, "@hi:localhost")
      assert [] = Core.all_typing(state)
    end
  end
end
