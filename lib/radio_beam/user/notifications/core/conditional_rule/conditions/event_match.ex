defmodule RadioBeam.User.Notifications.Core.ConditionalRule.Conditions.EventMatch do
  @moduledoc """
  Implementation of the `event_match` push rule condition

  https://spec.matrix.org/latest/client-server-api/#conditions-1
  """

  alias RadioBeam.Room.View.Core.Timeline.Event

  @doc """
  Returns an ok tuple with an arity-1 function or an error tuple. The function
  will return `true` when given an `t:RadioBeam.Room.View.Core.Timeline.Event`
  whose value under the `event_property_string` matches the given pattern.
  """
  def new(event_property_string, pattern) do
    match_word_boundaries? = event_property_string == "content.body"

    with {:ok, event_property_path} <- property_string_to_path(event_property_string),
         {:ok, pattern} <- compile_glob_style_pattern(pattern, not match_word_boundaries?) do
      predicate = if match_word_boundaries?, do: &matches_any_word?(&1, pattern), else: &String.match?(&1, pattern)

      {:ok,
       fn %Event{} = event ->
         event_map = event |> Event.to_map() |> Map.new(fn {k, v} -> {to_string(k), v} end)

         case get_in(event_map, event_property_path) do
           value when is_binary(value) -> predicate.(value)
           _not_a_string -> false
         end
       end}
    end
  end

  defp property_string_to_path(property_string) do
    if is_binary(property_string) and String.valid?(property_string) and String.printable?(property_string) do
      path =
        property_string
        # split on periods, as long as it's not preceeded by a `\`
        |> String.split(~r"[^\\](?<period>\.)", on: [:period])
        |> Enum.map(&String.replace(&1, "\\", ""))

      {:ok, path}
    else
      {:error, :invalid_key}
    end
  end

  # https://spec.matrix.org/latest/appendices/#glob-style-matching
  defp compile_glob_style_pattern(pattern, full_match?) do
    with :ok <- validate_reasonable_wildcard_count(pattern) do
      pattern
      |> String.split(wildcard_regex(), trim: true, include_captures: true)
      |> Enum.map_join(fn
        "?" -> "."
        "*" -> ".*"
        str -> Regex.escape(str)
      end)
      |> maybe_full_match(full_match?)
      |> Regex.compile("i")
    end
  end

  defp wildcard_regex, do: ~r"\?|\*"

  # genuine use cases shouldn't need more than this many wildcards (? and *) in a pattern
  @reasonable_wildcard_count 20
  defp validate_reasonable_wildcard_count(pattern) do
    if String.count(pattern, wildcard_regex()) > @reasonable_wildcard_count,
      do: {:error, :unreasonable_pattern},
      else: :ok
  end

  defp maybe_full_match(uncompiled_pat, true), do: "^#{uncompiled_pat}$"
  defp maybe_full_match(uncompiled_pat, false), do: uncompiled_pat

  defp matches_any_word?(string, pattern) do
    string |> String.split(word_boundaries_regex(), trim: true) |> Enum.any?(&String.match?(&1, pattern))
  end

  # this is a slightly expanded version of the spec defined set to include dashes (-) and apostrophes (').
  # Defined in the "event_match" condition description: https://spec.matrix.org/v1.18/client-server-api/#conditions-1
  defp word_boundaries_regex, do: ~r/[^A-Za-z0-9_\-']+/
end
