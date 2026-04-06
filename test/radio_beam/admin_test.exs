defmodule RadioBeam.AdminTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Admin
  alias RadioBeam.Admin.UserGeneratedReport
  alias RadioBeam.Room
  alias RadioBeam.User.LocalAccount

  describe "report_user/3" do
    test "inserts a new UserGeneratedReport" do
      %{user_id: spammer_id} = Fixtures.create_account()
      %{user_id: reporter_id} = Fixtures.create_account()

      assert {:ok, %UserGeneratedReport{} = report} = Admin.report_user(spammer_id, reporter_id, "spam")
      assert [^report] = Enum.filter(Admin.all_reports(), &(&1.target == spammer_id))
    end

    test "does not allow duplicate UserGeneratedReports" do
      %{user_id: spammer_id} = Fixtures.create_account()
      %{user_id: reporter_id} = Fixtures.create_account()

      assert {:ok, %UserGeneratedReport{} = report} = Admin.report_user(spammer_id, reporter_id, "spam")
      assert [^report] = Enum.filter(Admin.all_reports(), &(&1.target == spammer_id))

      assert {:error, :already_exists} = Admin.report_user(spammer_id, reporter_id, "please help they keep spamming")
      assert [^report] = Enum.filter(Admin.all_reports(), &(&1.target == spammer_id))
    end

    test "does not allow reports for non-existing users" do
      spammer_id = Fixtures.user_id()
      %{user_id: reporter_id} = Fixtures.create_account()

      assert {:error, :not_found} = Admin.report_user(spammer_id, reporter_id, "spam (not really)")
      assert [] = Enum.filter(Admin.all_reports(), &(&1.target == spammer_id))
    end

    test "does not allow reports from non-existing users" do
      %{user_id: spammer_id} = Fixtures.create_account()
      reporter_id = Fixtures.create_account()

      assert {:error, :not_found} = Admin.report_user(spammer_id, reporter_id, "spam (by anonymoous)")
      assert [] = Enum.filter(Admin.all_reports(), &(&1.target == spammer_id))
    end
  end

  describe "report_room/3" do
    test "inserts a new UserGeneratedReport" do
      %{user_id: creator_id} = Fixtures.create_account()
      {:ok, room_id} = Room.create(creator_id)
      %{user_id: reporter_id} = Fixtures.create_account()

      assert {:ok, %UserGeneratedReport{} = report} = Admin.report_room(room_id, reporter_id, "spam")
      assert [^report] = Enum.filter(Admin.all_reports(), &(&1.target == room_id))
    end

    test "does not allow duplicate UserGeneratedReports" do
      %{user_id: creator_id} = Fixtures.create_account()
      {:ok, room_id} = Room.create(creator_id)
      %{user_id: reporter_id} = Fixtures.create_account()

      assert {:ok, %UserGeneratedReport{} = report} = Admin.report_room(room_id, reporter_id, "spam")
      assert [^report] = Enum.filter(Admin.all_reports(), &(&1.target == room_id))

      assert {:error, :already_exists} = Admin.report_room(room_id, reporter_id, "please help they keep spamming")
      assert [^report] = Enum.filter(Admin.all_reports(), &(&1.target == room_id))
    end

    test "does not allow reports for non-existing rooms" do
      room_id = Fixtures.room_id()
      %{user_id: reporter_id} = Fixtures.create_account()

      assert {:error, :not_found} = Admin.report_room(room_id, reporter_id, "spam (not really)")
      assert [] = Enum.filter(Admin.all_reports(), &(&1.target == room_id))
    end

    test "does not allow reports from non-existing users" do
      %{user_id: spammer_id} = Fixtures.create_account()
      reporter_id = Fixtures.create_account()

      assert {:error, :not_found} = Admin.report_room(spammer_id, reporter_id, "spam (by anonymoous)")
      assert [] = Enum.filter(Admin.all_reports(), &(&1.target == spammer_id))
    end
  end

  describe "report_room_event/3" do
    test "inserts a new UserGeneratedReport" do
      %{user_id: creator_id} = Fixtures.create_account()
      {:ok, room_id} = Room.create(creator_id)
      %{user_id: reporter_id} = Fixtures.create_account()
      {:ok, _} = Room.invite(room_id, creator_id, reporter_id)
      {:ok, _} = Room.join(room_id, reporter_id)

      {:ok, event_id} = Room.send_text_message(room_id, creator_id, "pancakes > waffles")

      assert {:ok, %UserGeneratedReport{} = report} = Admin.report_room_event(room_id, event_id, reporter_id, "wrong")
      assert [^report] = Enum.filter(Admin.all_reports(), &(&1.target == {room_id, event_id}))
    end

    test "does not allow duplicate UserGeneratedReports" do
      %{user_id: creator_id} = Fixtures.create_account()
      {:ok, room_id} = Room.create(creator_id)
      %{user_id: reporter_id} = Fixtures.create_account()
      {:ok, _} = Room.invite(room_id, creator_id, reporter_id)
      {:ok, _} = Room.join(room_id, reporter_id)

      {:ok, event_id} = Room.send_text_message(room_id, creator_id, "pancakes > waffles")

      assert {:ok, %UserGeneratedReport{} = report} = Admin.report_room_event(room_id, event_id, reporter_id, "wrong")
      assert [^report] = Enum.filter(Admin.all_reports(), &(&1.target == {room_id, event_id}))

      assert {:error, :already_exists} = Admin.report_room_event(room_id, event_id, reporter_id, "pls ban them")
      assert [^report] = Enum.filter(Admin.all_reports(), &(&1.target == {room_id, event_id}))
    end

    test "does not allow reports for non-existing events" do
      %{user_id: creator_id} = Fixtures.create_account()
      {:ok, room_id} = Room.create(creator_id)
      %{user_id: reporter_id} = Fixtures.create_account()
      {:ok, _} = Room.invite(room_id, creator_id, reporter_id)
      {:ok, _} = Room.join(room_id, reporter_id)

      event_id = "$abcde"

      assert {:error, :not_found} = Admin.report_room_event(room_id, event_id, reporter_id, "spam (not really)")
      assert [] = Enum.filter(Admin.all_reports(), &(&1.target == {room_id, event_id}))
    end

    test "does not allow reports from users not in the room" do
      %{user_id: creator_id} = Fixtures.create_account()
      {:ok, room_id} = Room.create(creator_id)
      %{user_id: reporter_id} = Fixtures.create_account()

      {:ok, event_id} = Room.send_text_message(room_id, creator_id, "pancakes > waffles")

      assert {:error, :not_a_member} = Admin.report_room_event(room_id, event_id, reporter_id, "spam")
      assert [] = Enum.filter(Admin.all_reports(), &(&1.target == {room_id, event_id}))
    end

    test "does not allow reports from non-existing users" do
      %{user_id: creator_id} = Fixtures.create_account()
      {:ok, room_id} = Room.create(creator_id)
      reporter_id = Fixtures.create_account()

      {:ok, event_id} = Room.send_text_message(room_id, creator_id, "pancakes > waffles")

      assert {:error, :not_found} = Admin.report_room_event(room_id, event_id, reporter_id, "spam (by anonymoous)")
      assert [] = Enum.filter(Admin.all_reports(), &(&1.target == {room_id, event_id}))
    end
  end

  describe "lock_account/2,3" do
    test "locks the given account, optionally specifying a DateTime to automatically unlock it" do
      account = Fixtures.create_account()
      [admin_id | _] = RadioBeam.Config.admins()

      refute LocalAccount.locked?(account)

      assert {:ok, %LocalAccount{} = locked_account} = Admin.lock_account(account.user_id, admin_id)
      assert LocalAccount.locked?(locked_account)

      assert {:ok, %LocalAccount{} = locked_account2} =
               Admin.lock_account(account.user_id, admin_id, DateTime.add(DateTime.utc_now(), 1, :second))

      assert LocalAccount.locked?(locked_account2)

      Process.sleep(:timer.seconds(1) + 1)

      refute LocalAccount.locked?(locked_account2)
    end
  end

  describe "unlock_account/2" do
    test "unlocks the given account" do
      account = Fixtures.create_account()
      [admin_id | _] = RadioBeam.Config.admins()

      refute LocalAccount.locked?(account)

      {:ok, %LocalAccount{} = account} = Admin.lock_account(account.user_id, admin_id)
      assert LocalAccount.locked?(account)

      assert {:ok, %LocalAccount{} = account} = Admin.unlock_account(account.user_id, admin_id)
      refute LocalAccount.locked?(account)
    end
  end
end
