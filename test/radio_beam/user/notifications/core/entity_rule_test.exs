defmodule RadioBeam.User.Notifications.Core.EntityRuleTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.View.Core.Timeline
  alias RadioBeam.User.Notifications.Core.EntityRule

  describe "new/3,4" do
    setup do
      rule_id = 3..30 |> Enum.random() |> Fixtures.random_string()

      %{user_id: user_id} = Fixtures.create_account()

      {:sent, room, message_id, _} = "12" |> Fixtures.room(user_id) |> Fixtures.send_room_msg(user_id, "yooo")

      timeline = Fixtures.make_room_view(Timeline, room)

      [event] =
        Timeline.get_visible_events(timeline, [message_id], user_id, &Room.Chronicle.fetch_pdu!(room.chronicle, &1))
        |> Enum.to_list()

      actions = [%{"set_tweak" => "sound", "value" => "default"}, "notify"]

      %{rule_id: rule_id, user_id: user_id, room: room, event: event, actions: actions}
    end

    test "creates a new valid content rule", %{
      rule_id: rule_id,
      actions: actions,
      event: event
    } do
      assert {:ok, %EntityRule{} = rule} = EntityRule.new(rule_id, actions, true, {:content, "yo*"})
      assert length(actions) == rule |> EntityRule.actions() |> length()
      assert EntityRule.event_passes_conditions?(rule, event)

      assert {:ok, %EntityRule{} = rule} = EntityRule.new(rule_id, actions, true, {:content, "yo?!"})
      assert length(actions) == rule |> EntityRule.actions() |> length()
      refute EntityRule.event_passes_conditions?(rule, event)
    end

    test "creates a new valid room rule", %{
      actions: actions,
      room: room,
      event: event
    } do
      assert {:ok, %EntityRule{} = rule} = EntityRule.new(room.id, actions, true, :room)
      assert length(actions) == rule |> EntityRule.actions() |> length()
      assert EntityRule.event_passes_conditions?(rule, event)

      assert {:ok, %EntityRule{} = rule} = EntityRule.new(room.id, actions, true, :room)
      assert length(actions) == rule |> EntityRule.actions() |> length()
      refute EntityRule.event_passes_conditions?(rule, put_in(event.room_id, "!incorrect_room"))
    end

    test "creates a new valid sender rule", %{
      actions: actions,
      user_id: user_id,
      event: event
    } do
      assert {:ok, %EntityRule{} = rule} = EntityRule.new(user_id, actions, true, :sender)
      assert length(actions) == rule |> EntityRule.actions() |> length()
      assert EntityRule.event_passes_conditions?(rule, event)

      assert {:ok, %EntityRule{} = rule} = EntityRule.new(user_id, actions, true, :sender)
      assert length(actions) == rule |> EntityRule.actions() |> length()
      refute EntityRule.event_passes_conditions?(rule, put_in(event.sender, "@someone:else"))
    end

    test "errors when entity is content and pattern is invalid", %{
      rule_id: rule_id
    } do
      for invalid_pattern <- [1, 2.4, nil, true, <<1::3>>] do
        assert {:error, :entity_type} = EntityRule.new(rule_id, [], true, {:content, invalid_pattern})
      end

      for invalid_pattern <- ["hi" <> <<0>>, <<1>>] do
        assert {:error, :invalid_pattern} = EntityRule.new(rule_id, [], true, {:content, invalid_pattern})
      end
    end

    test "errors when entity is room and rule_id is not a room_id" do
      not_a_room_id = "asdf"

      assert {:error, {:invalid_rule_id_for_entity, ^not_a_room_id, :room}} =
               EntityRule.new(not_a_room_id, [], true, :room)
    end

    test "errors when entity is sender and rule_id is not a user_id" do
      not_a_user_id = "asdf"

      assert {:error, {:invalid_rule_id_for_entity, ^not_a_user_id, :sender}} =
               EntityRule.new(not_a_user_id, [], true, :sender)
    end
  end
end
