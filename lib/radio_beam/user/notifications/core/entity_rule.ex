defmodule RadioBeam.User.Notifications.Core.EntityRule do
  @moduledoc """
  A parsed content, room, or sender PushRule as defined by [the
  spec](https://spec.matrix.org/latest/client-server-api/#get_matrixclientv3pushrulesglobalkindruleid)
  """

  alias RadioBeam.User.Notifications.Core.ConditionalRule

  defstruct ~w|entity_type conditional_rule|a

  @type entity_type() :: {:content, String.t()} | :room | :sender

  @opaque t() :: %__MODULE__{entity_type: entity_type(), conditional_rule: ConditionalRule.t()}

  defguardp is_entity_type(type)
            when type in ~w|room sender|a or (is_tuple(type) and elem(type, 0) == :content and is_binary(elem(type, 1)))

  def new(id, actions, enabled?, type) when is_entity_type(type) do
    with {:ok, raw_conditions} <- conditions_from_type(type, id),
         {:ok, %ConditionalRule{} = cond_rule} <- ConditionalRule.new(id, actions, raw_conditions, enabled?) do
      {:ok, %__MODULE__{entity_type: type, conditional_rule: cond_rule}}
    end
  end

  def new(_, _, _, _), do: {:error, :entity_type}

  def id(%__MODULE__{} = rule), do: ConditionalRule.id(rule.conditional_rule)
  def enabled?(%__MODULE__{} = rule), do: ConditionalRule.enabled?(rule.conditional_rule)
  def actions(%__MODULE__{} = rule), do: ConditionalRule.actions(rule.conditional_rule)
  def pattern(%__MODULE__{entity_type: {:content, pattern}}), do: pattern
  def pattern(%__MODULE__{}), do: nil

  def event_passes_conditions?(%__MODULE__{} = rule, event),
    do: ConditionalRule.event_passes_conditions?(rule.conditional_rule, event)

  defp conditions_from_type({:content, pattern}, _id),
    do: {:ok, [%{"kind" => "event_match", "key" => "content.body", "pattern" => pattern}]}

  defp conditions_from_type(:room, "!" <> _ = rule_room_id),
    do: {:ok, [%{"kind" => "event_property_is", "key" => "room_id", "value" => rule_room_id}]}

  defp conditions_from_type(:room, not_a_room_id), do: {:error, {:invalid_rule_id_for_entity, not_a_room_id, :room}}

  defp conditions_from_type(:sender, "@" <> _ = rule_sender_id),
    do: {:ok, [%{"kind" => "event_property_is", "key" => "sender", "value" => rule_sender_id}]}

  defp conditions_from_type(:sender, not_a_user_id), do: {:error, {:invalid_rule_id_for_entity, not_a_user_id, :sender}}

  defimpl JSON.Encoder do
    alias RadioBeam.User.Notifications.Core.EntityRule

    def encode(rule, encoder) do
      %{
        rule_id: EntityRule.id(rule),
        actions: EntityRule.actions(rule),
        enabled: EntityRule.enabled?(rule),
        default: false
      }
      |> put_pattern_for_content(rule.entity_type)
      |> JSON.Encoder.Map.encode(encoder)
    end

    defp put_pattern_for_content(map_rule, {:content, pattern}), do: Map.put(map_rule, :pattern, pattern)
    defp put_pattern_for_content(map_rule, _not_content), do: map_rule
  end
end
