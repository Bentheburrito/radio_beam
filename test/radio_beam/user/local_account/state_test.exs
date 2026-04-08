defmodule RadioBeam.User.LocalAccount.StateTest do
  use ExUnit.Case, async: true

  alias RadioBeam.User.LocalAccount.State

  describe "new!/1,2" do
    test "creates a new :locked %State{} with the given opts" do
      changed_at = DateTime.from_unix!(0)
      effective_until = DateTime.add(DateTime.utc_now(), 1, :day)

      changed_by = Fixtures.user_id()

      assert %State{changed_by_id: changed_by, changed_at: ^changed_at, effective_until: ^effective_until} =
               State.new!(:locked, changed_by, changed_at: changed_at, effective_until: effective_until)

      assert %State{changed_by_id: ^changed_by, changed_at: default_changed_at, effective_until: :infinity} =
               State.new!(:locked, changed_by)

      assert DateTime.compare(changed_at, default_changed_at) in ~w|lt eq|a
      assert DateTime.compare(default_changed_at, DateTime.utc_now()) in ~w|lt eq|a
    end
  end
end
