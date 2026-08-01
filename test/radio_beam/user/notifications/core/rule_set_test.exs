defmodule RadioBeam.User.Notifications.Core.RuleSetTest do
  use ExUnit.Case, async: true

  alias RadioBeam.Room
  alias RadioBeam.Room.View.Core.Timeline
  alias RadioBeam.User.Notifications.Core.ConditionalRule
  alias RadioBeam.User.Notifications.Core.RuleSet

  describe "put_rule/3" do
    test "accepts override/underride `ConditionalRule`s" do
      rule_set = RuleSet.new!()

      for kind <- ~w|override underride|a do
        {:ok, rule} = ConditionalRule.new("rule_#{Fixtures.random_string(12)}", ["notify"], [], true)
        assert :not_found = RuleSet.get_rule(rule_set, kind, rule.id)
        assert %RuleSet{} = rule_set = RuleSet.put_rule(rule_set, kind, rule)
        assert ^rule = RuleSet.get_rule(rule_set, kind, rule.id)
      end
    end
  end

  describe "delete_rule/3" do
    test "deletes override/underride rules, if they exist in the set" do
      rule_set = RuleSet.new!()

      for kind <- ~w|override underride|a do
        {:ok, rule} = ConditionalRule.new("rule_#{Fixtures.random_string(12)}", ["notify"], [], true)
        %RuleSet{} = rule_set = RuleSet.put_rule(rule_set, kind, rule)
        assert ^rule = RuleSet.get_rule(rule_set, kind, rule.id)
        assert %RuleSet{} = rule_set = RuleSet.delete_rule(rule_set, kind, rule.id)
        assert :not_found = RuleSet.get_rule(rule_set, kind, rule.id)
        assert ^rule_set = RuleSet.delete_rule(rule_set, kind, rule.id)
      end
    end
  end

  describe "evaluate_event/2" do
    setup do
      %{user_id: user_id} = Fixtures.create_account()

      {:sent, room, message_id, _} = "12" |> Fixtures.room(user_id) |> Fixtures.send_room_msg(user_id, "yooo")

      timeline = Fixtures.make_room_view(Timeline, room)

      [event] =
        Timeline.get_visible_events(timeline, [message_id], user_id, &Room.Chronicle.fetch_pdu!(room.chronicle, &1))
        |> Enum.to_list()

      %{rule_set: RuleSet.new!(), event: event}
    end

    @sound_tweak %{"set_tweak" => "sound", "value" => "default"}
    @wont_match_cond %{"kind" => "event_match", "key" => "content.body", "pattern" => "lalalalala?"}
    test "returns the actions of the first matching event", %{rule_set: rule_set, event: event} do
      always_matches = unconditional_match(["notify"], true)
      always_matches2 = unconditional_match([@sound_tweak], true)

      {:ok, wont_match_event} =
        ConditionalRule.new("rule_#{Fixtures.random_string(12)}", ["notify"], [@wont_match_cond], true)

      rule_set =
        rule_set
        |> RuleSet.put_rule(:override, always_matches)
        |> RuleSet.put_rule(:override, always_matches2)
        |> RuleSet.put_rule(:override, wont_match_event)

      assert [%{set_tweak: "sound", value: "default"}] = RuleSet.evaluate_event(rule_set, event)
    end

    test "returns the actions of the first matching AND enabled event", %{rule_set: rule_set, event: event} do
      always_matches = unconditional_match(["notify"], true)
      always_matches2 = unconditional_match([@sound_tweak], false)

      rule_set = rule_set |> RuleSet.put_rule(:override, always_matches) |> RuleSet.put_rule(:override, always_matches2)

      assert [:notify] = RuleSet.evaluate_event(rule_set, event)
    end

    test "returns the actions of the first matching event, in order of the rule `kind`s", %{
      rule_set: rule_set,
      event: event
    } do
      always_matches = unconditional_match(["notify"], true)
      always_matches2 = unconditional_match([@sound_tweak], true)

      rule_set =
        rule_set |> RuleSet.put_rule(:override, always_matches) |> RuleSet.put_rule(:underride, always_matches2)

      assert [:notify] = RuleSet.evaluate_event(rule_set, event)
    end
  end

  defp unconditional_match(actions, enabled?) do
    {:ok, rule} = ConditionalRule.new("rule_#{Fixtures.random_string(12)}", actions, [], enabled?)
    rule
  end
end
