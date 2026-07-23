defmodule RadioBeam.User.Notifications.Core.ConditionalRuleTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.View.Core.Timeline
  alias RadioBeam.User.Notifications.Core.ConditionalRule

  describe "new/3,4" do
    setup do
      rule_id = 3..30 |> Enum.random() |> Fixtures.random_string()

      possible_actions = [%{"set_tweak" => "sound", "value" => "default"}, "notify"]

      actions_power_set = power_set(possible_actions)

      possible_conditions = [
        %{"kind" => "event_match", "key" => "content.body", "pattern" => "targetvalue"},
        %{"kind" => "event_match", "key" => "content.value", "pattern" => "123123"}
      ]

      conditions_power_set = power_set(possible_conditions)

      %{rule_id: rule_id, actions_power_set: actions_power_set, conditions_power_set: conditions_power_set}
    end

    test "creates a new valid rule", %{
      rule_id: rule_id,
      actions_power_set: actions_power_set,
      conditions_power_set: conditions_power_set
    } do
      for actions <- actions_power_set, conditions <- conditions_power_set, enabled? <- ~w|true false|a do
        assert {:ok, %ConditionalRule{} = rule} = ConditionalRule.new(rule_id, actions, conditions, enabled?)
        assert length(actions) == rule |> ConditionalRule.actions() |> length()
        assert ^rule_id = ConditionalRule.id(rule)
      end
    end

    test "errors with :invalid_actions when given invalid actions", %{
      rule_id: rule_id,
      conditions_power_set: conditions_power_set
    } do
      for actions <- ["not-a-list", [123], ["unknown-action"]],
          conditions <- conditions_power_set,
          enabled? <- ~w|true false|a do
        assert {:error, :invalid_actions} = ConditionalRule.new(rule_id, actions, conditions, enabled?)
      end
    end

    test "ignores historic actions", %{rule_id: rule_id, conditions_power_set: conditions_power_set} do
      for actions <- [["dont_notify"], ["coalesce"]],
          conditions <- conditions_power_set,
          enabled? <- ~w|true false|a do
        assert {:ok, %ConditionalRule{} = rule} = ConditionalRule.new(rule_id, actions, conditions, enabled?)
        assert [] = ConditionalRule.actions(rule)
      end
    end

    test "errors with :invalid_conditions when given invalid conditions", %{
      rule_id: rule_id,
      actions_power_set: actions_power_set
    } do
      for actions <- actions_power_set,
          conditions <- [
            "not-a-list",
            [%{"kind" => "event_match", "keyyyy" => "content.body", "pattern" => "abc"}],
            [%{"kind" => "wtf_is_even_this"}]
          ],
          enabled? <- ~w|true false|a do
        assert {:error, :invalid_conditions} = ConditionalRule.new(rule_id, actions, conditions, enabled?)
      end
    end

    test "errors with :enabled? when enabled? is not a bool", %{
      rule_id: rule_id,
      actions_power_set: actions_power_set,
      conditions_power_set: conditions_power_set
    } do
      for actions <- actions_power_set, conditions <- conditions_power_set, enabled? <- ~w|blech false true| do
        assert {:error, :enabled?} = ConditionalRule.new(rule_id, actions, conditions, enabled?)
      end
    end

    test "errors with :rule_id when the given rule ID is invalid", %{
      actions_power_set: actions_power_set,
      conditions_power_set: conditions_power_set
    } do
      for rule_id <- [".m.cant.start.with.period", 123, "💩"],
          actions <- actions_power_set,
          conditions <- conditions_power_set,
          enabled? <- ~w|true false|a do
        assert {:error, :rule_id} = ConditionalRule.new(rule_id, actions, conditions, enabled?)
      end
    end
  end

  describe "event_passes_conditions?/2" do
    setup do
      %{user_id: user_id} = Fixtures.create_account()

      {:sent, room, message_id, _} = "12" |> Fixtures.room(user_id) |> Fixtures.send_room_msg(user_id, "yooo")

      timeline = Fixtures.make_room_view(Timeline, room)

      [event] =
        Timeline.get_visible_events(timeline, [message_id], user_id, &Room.Chronicle.fetch_pdu!(room.chronicle, &1))
        |> Enum.to_list()

      actions = [%{"set_tweak" => "sound", "value" => "default"}, "notify"]

      conditions = [
        %{"kind" => "event_match", "key" => "content.body", "pattern" => "?ooo"},
        %{"kind" => "event_match", "key" => "content.body", "pattern" => "yo*"},
        %{"kind" => "event_match", "key" => "type", "pattern" => "m.room.*"}
      ]

      %{event: event, actions: actions, conditions: Enum.shuffle(conditions)}
    end

    test "returns `true` only when all conditions are `true`", %{event: event, actions: actions, conditions: conditions} do
      Enum.reduce(conditions, [], fn condition, conditions ->
        conditions = [condition | conditions]
        {:ok, rule} = ConditionalRule.new("rule", actions, conditions, true)
        assert ConditionalRule.event_passes_conditions?(rule, event)
        conditions
      end)
    end

    test "returns `false` when any condition is `false`", %{event: event, actions: actions, conditions: conditions} do
      Enum.reduce(conditions, [], fn condition, conditions ->
        conditions = [condition | conditions]
        bad_conditions = Enum.shuffle([put_in(condition["pattern"], "?ello!") | conditions])

        {:ok, rule} = ConditionalRule.new("rule", actions, bad_conditions, true)

        refute ConditionalRule.event_passes_conditions?(rule, event)
        conditions
      end)
    end
  end

  # https://stackoverflow.com/questions/8126392/generate-a-powerset-of-a-set-containing-only-subsets-of-a-certain-size
  defp power_set([]), do: [[]]

  defp power_set([head | tail]) do
    power_set_of_tail = power_set(tail)
    power_set(head, power_set_of_tail, power_set_of_tail)
  end

  defp power_set(_, [], acc), do: acc
  defp power_set(current, [head | tail], acc), do: power_set(current, tail, [[current | head] | acc])
end
