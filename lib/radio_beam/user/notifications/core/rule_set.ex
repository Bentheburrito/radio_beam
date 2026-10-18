defmodule RadioBeam.User.Notifications.Core.RuleSet do
  @moduledoc """
  Defines a parsed user-supplied ruleset alongside server-default push rules.

  The `enabled?` property takes place of the spec's `.m.rule.master`
  server-defined default override rule. Furthermore, `override_default` and
  `underride_default` contain the server-defined default rules.
  """
  alias RadioBeam.Room.View.Core.Timeline.Event
  alias RadioBeam.User.Notifications.Core.EntityRule
  alias RadioBeam.User.Notifications.Core.ConditionalRule

  defstruct ~w|enabled? override override_default content room sender underride underride_default put_count|a
  @opaque t() :: %__MODULE__{}

  @rule_kinds ~w|override content room sender underride|a

  def new! do
    %__MODULE__{
      enabled?: true,
      override: %{},
      override_default: %{},
      content: %{},
      room: %{},
      sender: %{},
      underride: %{},
      underride_default: %{},
      put_count: 0
    }
  end

  @doc """
  Adds a rule to the `t:#{__MODULE__}.t`. Newer rules take precedence over
  older rules of the same `kind`.
  """
  def put_rule(%__MODULE__{} = rule_set, kind, %rule_type{} = rule)
      when kind in @rule_kinds and rule_type in [ConditionalRule, EntityRule] do
    #### TOFIX: make it so that updated rules (i.e. if rule.id is already
    #    present in rule_set) do not change priority automatically
    value = {rule, _rule_priority = rule_set.put_count}
    rule_set = update_in(rule_set.put_count, &(&1 + 1))

    case kind do
      :override -> put_in(rule_set.override[rule_type.id(rule)], value)
      :content -> put_in(rule_set.content[rule_type.id(rule)], value)
      :room -> put_in(rule_set.room[rule_type.id(rule)], value)
      :sender -> put_in(rule_set.sender[rule_type.id(rule)], value)
      :underride -> put_in(rule_set.underride[rule_type.id(rule)], value)
    end
  end

  def get_rule(%__MODULE__{} = rule_set, kind, rule_id) when kind in @rule_kinds do
    case kind do
      :override ->
        rule_set.override
        |> Map.get_lazy(rule_id, fn -> Map.get(rule_set.override_default, rule_id, {:not_found, 0}) end)
        |> elem(0)

      :content ->
        rule_set.content |> Map.get(rule_id, {:not_found, 0}) |> elem(0)

      :room ->
        rule_set.room |> Map.get(rule_id, {:not_found, 0}) |> elem(0)

      :sender ->
        rule_set.sender |> Map.get(rule_id, {:not_found, 0}) |> elem(0)

      :underride ->
        rule_set.underride
        |> Map.get_lazy(rule_id, fn -> Map.get(rule_set.underride_default, rule_id, {:not_found, 0}) end)
        |> elem(0)
    end
  end

  def delete_rule(%__MODULE__{} = rule_set, kind, rule_id) when kind in @rule_kinds do
    case kind do
      :override -> rule_set.override[rule_id] |> pop_in() |> elem(1)
      :content -> rule_set.content[rule_id] |> pop_in() |> elem(1)
      :room -> rule_set.room[rule_id] |> pop_in() |> elem(1)
      :sender -> rule_set.sender[rule_id] |> pop_in() |> elem(1)
      :underride -> rule_set.underride[rule_id] |> pop_in() |> elem(1)
    end
  end

  @doc """
  Evaluates the given event against a `t:#{__MODULE__}.t`.

  https://spec.matrix.org/latest/client-server-api/#push-rules
  """
  def evaluate_event(%__MODULE__{enabled?: false}, _event), do: _no_actions = []

  def evaluate_event(%__MODULE__{enabled?: true} = rule_set, %Event{} = event) do
    [
      rule_set.override,
      rule_set.override_default,
      rule_set.content,
      rule_set.room,
      rule_set.sender,
      rule_set.underride,
      rule_set.underride_default
    ]
    |> Stream.flat_map(&filter_and_sort_rules/1)
    |> Enum.find_value(_no_actions = [], fn %rule_type{} = rule ->
      if rule_type.event_passes_conditions?(rule, event) do
        rule_type.actions(rule)
      else
        _continue_searching = false
      end
    end)
  end

  defp filter_and_sort_rules(rule_pairs) do
    rule_pairs
    |> Stream.filter(fn {_rule_id, {rule, _priority}} -> enabled?(rule) end)
    # TOIMPL: support manual ordering of individual rules within a `kind`
    |> Enum.sort_by(fn {_rule_id, {_rule, priority}} -> priority end, :desc)
    |> Stream.map(fn {_rule_id, {rule, _priority}} -> rule end)
  end

  defp enabled?(%ConditionalRule{} = rule), do: ConditionalRule.enabled?(rule)
  defp enabled?(%EntityRule{} = rule), do: EntityRule.enabled?(rule)

  defimpl JSON.Encoder do
    def encode(rule_set, encoder) do
      JSON.Encoder.Map.encode(
        %{
          override:
            rule_set.override
            |> Stream.concat(rule_set.override_default)
            |> Enum.map(fn {_, {rule, _priority}} -> rule end),
          content: Enum.map(rule_set.content, fn {_, {rule, _priority}} -> rule end),
          room: Enum.map(rule_set.room, fn {_, {rule, _priority}} -> rule end),
          sender: Enum.map(rule_set.sender, fn {_, {rule, _priority}} -> rule end),
          underride:
            rule_set.underride
            |> Stream.concat(rule_set.underride_default)
            |> Enum.map(fn {_, {rule, _priority}} -> rule end)
        },
        encoder
      )
    end
  end
end
