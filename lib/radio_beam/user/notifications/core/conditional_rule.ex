defmodule RadioBeam.User.Notifications.Core.ConditionalRule do
  @moduledoc """
  A parsed override or underride PushRule defined by [the spec](https://spec.matrix.org/v1.18/client-server-api/#get_matrixclientv3pushrulesglobalkindruleid)
  """

  alias RadioBeam.Room.View.Core.Timeline.Event
  alias RadioBeam.User.Notifications.Core.ConditionalRule.Conditions

  defstruct ~w|id actions conditions enabled?|a

  @typep rule_id() :: String.t()
  @typep action() :: :notify | %{set_tweak: String.t()} | %{set_tweak: String.t(), value: any()}
  @typep condition() :: (Event.t() -> boolean())

  @opaque t() :: %__MODULE__{id: rule_id(), actions: [action()], conditions: [condition()], enabled?: boolean()}

  def new(id, actions, conditions, enabled?) when is_boolean(enabled?) do
    with :ok <- validate_rule_id(id),
         {:ok, actions} <- parse_actions(actions),
         {:ok, conditions} <- parse_conditions(conditions) do
      {:ok, %__MODULE__{id: id, actions: actions, conditions: conditions, enabled?: enabled?}}
    end
  end

  def new(_, _, _, _), do: {:error, :enabled?}

  # note: we're enforcing a more restrictive alphabet for rule IDs than defined
  # by the spec:
  # > The identifier for the rule. If the string starts with a dot ("."), the
  # > request MUST be rejected as this is reserved for server-default rules.
  # > Slashes ("/") and backslashes ("\") are also not allowed.
  # https://spec.matrix.org/v1.18/client-server-api/#put_matrixclientv3pushrulesglobalkindruleid
  defp validate_rule_id(rule_id) do
    if is_binary(rule_id) and not String.starts_with?(rule_id, ".") and String.match?(rule_id, ~r/^[a-zA-Z0-9_\-\.]+$/),
      do: :ok,
      else: {:error, :rule_id}
  end

  defp parse_actions(action_params) when is_list(action_params) do
    action_params
    |> Enum.reduce_while([], fn action_param, actions ->
      case parse_action(action_param) do
        {:ok, action} -> {:cont, [action | actions]}
        :ignore -> {:cont, actions}
        :error -> {:halt, {:error, :actions}}
      end
    end)
    |> rev_list_with_ok()
  end

  defp parse_actions(_action_params), do: {:error, :actions}

  defp parse_action("notify"), do: {:ok, :notify}

  defp parse_action(%{"set_tweak" => tweak_name} = tweak) do
    if is_binary(tweak_name) and String.valid?(tweak_name),
      do: {:ok, maybe_put_value(%{set_tweak: tweak_name}, tweak["value"])},
      else: :error
  end

  # https://spec.matrix.org/latest/client-server-api/#historical-actions
  @historic_actions_to_strip ~w|dont_notify coalesce|
  defp parse_action(action) when action in @historic_actions_to_strip, do: :ignore
  defp parse_action(_unknown_action), do: :error

  defp maybe_put_value(tweak, nil), do: tweak
  defp maybe_put_value(tweak, value), do: Map.put(tweak, :value, value)

  defp rev_list_with_ok(list) when is_list(list), do: {:ok, Enum.reverse(list)}
  defp rev_list_with_ok(not_a_list), do: not_a_list

  defp parse_conditions(conditions_params) when is_list(conditions_params) do
    conditions_params
    |> Enum.reduce_while([], fn condition_param, conditions ->
      case parse_condition(condition_param) do
        {:ok, condition} -> {:cont, [condition | conditions]}
        :error -> {:halt, {:error, :conditions}}
      end
    end)
    |> rev_list_with_ok()
  end

  defp parse_conditions(_conditions_params), do: {:error, :conditions}

  defdelegate parse_condition(params), to: Conditions, as: :parse

  def id(%__MODULE__{id: id}), do: id
  def enabled?(%__MODULE__{enabled?: enabled?}), do: enabled?
  def actions(%__MODULE__{actions: actions}), do: actions

  def event_passes_conditions?(%__MODULE__{} = rule, event) do
    Enum.all?(rule.conditions, & &1.(event))
  end
end
