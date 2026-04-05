defmodule RadioBeam.User.LocalAccount.LockStateTest do
  use ExUnit.Case, async: true

  alias RadioBeam.User.LocalAccount.LockState

  describe "new!/1,2" do
    test "creates a new %LockState{} with the given opts" do
      locked_at = DateTime.from_unix!(0)
      locked_until = DateTime.add(DateTime.utc_now(), 1, :day)

      locked_by = Fixtures.user_id()

      assert %LockState{locked_by_id: locked_by, locked_at: ^locked_at, locked_until: ^locked_until} =
               LockState.new!(locked_by, locked_at: locked_at, locked_until: locked_until)

      assert %LockState{locked_by_id: ^locked_by, locked_at: default_locked_at, locked_until: :infinity} =
               LockState.new!(locked_by)

      assert DateTime.compare(locked_at, default_locked_at) in ~w|lt eq|a
      assert DateTime.compare(default_locked_at, DateTime.utc_now()) in ~w|lt eq|a
    end
  end
end
