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
  def new(event_property_string, value, compare \\ :exact)

  def new(event_property_string, value, compare)
      when is_non_compound(value) and
             compare in ~w|exact contains|a do
    with {:ok, event_property_path} <- AccessExtras.property_string_to_path(event_property_string),
         :ok <- validate_string(value) do
      {:ok,
       fn %Event{} = event ->
         event_map = event |> Event.to_map() |> Map.new(fn {k, v} -> {to_string(k), v} end)

         case compare do
           :exact -> match?(^value, get_in(event_map, event_property_path))
           :contains -> Enum.any?(get_list_in_safe(event_map, event_property_path), &match?(^value, &1))
         end
       end}
    end
  end

  def new(_event_property_string, value, _compare), do: {:error, {:invalid_value, value}}

  defp validate_string(value) when is_binary(value) do
    if String.valid?(value) and String.printable?(value), do: :ok, else: {:error, {:invalid_value, value}}
  end

  defp validate_string(_not_supposed_to_be_a_str), do: :ok

  defp get_list_in_safe(event_map, event_property_path) do
    case get_in(event_map, event_property_path) do
      list when is_list(list) -> list
      _some_other_type -> []
    end
  end
end
