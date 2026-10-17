defmodule RadioBeam.User.Notifications.Core.ConditionalRule.Conditions.EventPropertyIs do
  @moduledoc """
  Implementation of the `event_property_is` push rule condition

  https://spec.matrix.org/latest/client-server-api/#conditions-1
  """

  alias RadioBeam.Room.View.Core.Timeline.Event
  alias RadioBeam.AccessExtras

  # The match is performed exactly and only supports non-compound canonical
  # JSON values: strings, integers in the range of [-(2**53)+1, (2**53)-1],
  # booleans, and null.
  @canonical_json_int_range (-(2 ** 53) + 1)..(2 ** 53 - 1)
  defguardp is_non_compound(value)
            when is_binary(value) or (is_integer(value) and value in @canonical_json_int_range) or
                   value in ~w|true false nil|a

  @doc """
  Returns an ok tuple with an arity-1 function or an error tuple. The function
  will return `true` when given an `t:RadioBeam.Room.View.Core.Timeline.Event`
  whose value under the `event_property_string` matches the given value.
  """
  def new(event_property_string, value) when is_non_compound(value) do
    with {:ok, event_property_path} <- AccessExtras.property_string_to_path(event_property_string),
         :ok <- validate_string(value) do
      {:ok,
       fn %Event{} = event ->
         event_map = event |> Event.to_map() |> Map.new(fn {k, v} -> {to_string(k), v} end)

         match?(^value, get_in(event_map, event_property_path))
       end}
    end
  end

  def new(_event_property_string, value), do: {:error, {:invalid_value, value}}

  defp validate_string(value) do
    if String.valid?(value) and String.printable?(value), do: :ok, else: {:error, {:invalid_value, value}}
  end
end
