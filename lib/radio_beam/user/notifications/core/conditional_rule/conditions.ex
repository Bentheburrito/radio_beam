defmodule RadioBeam.User.Notifications.Core.ConditionalRule.Conditions do
  @moduledoc """
  [Push Rule Conditions](https://spec.matrix.org/latest/client-server-api/#conditions-1)
  """
  alias RadioBeam.User.Notifications.Core.ConditionalRule.Conditions.EventMatch
  alias RadioBeam.User.Notifications.Core.ConditionalRule.Conditions.EventPropertyIs

  @doc """
  Returns `{:ok, fun/1}` or `:error`, where `fun/1` is a predicate
  function that takes a `t:RadioBeam.Room.View.Core.Timeline.Event` and returns
  a `boolean()`. `true` indicates the event matched the condition, possibly
  triggering a notification (if other corresponding conditions match too).
  """
  def parse(%{"kind" => "event_match", "key" => key, "pattern" => pattern}), do: EventMatch.new(key, pattern)
  def parse(%{"kind" => "event_property_is", "key" => key, "value" => v}), do: EventPropertyIs.new(key, v, :exact)
  def parse(%{"kind" => "event_property_contains", "key" => k, "value" => v}), do: EventPropertyIs.new(k, v, :contains)
  def parse(_params), do: :error
end
