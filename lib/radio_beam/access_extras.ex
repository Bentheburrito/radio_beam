defmodule RadioBeam.AccessExtras do
  @moduledoc """
  Helper functions extending `Access` functionality.
  """

  @doc """
  Similar to `put_in/3`, but will create keys in `path` if they do not exist.
  """
  @spec put_nested(Access.t(), list(), any()) :: Access.t()
  def put_nested(data, path, value) do
    put_in(data, Enum.map(path, &Access.key(&1, %{})), value)
  end

  @doc """
  Parse a Matrix nested-property string (e.g. `event.content.body`) into a path
  (`["event", "content", "body"]`).

  This function aims to be a spec-compliant of these property strings,
  including escaped periods (\\.)

  ## Examples

    iex> RadioBeam.AccessExtras.property_string_to_path("event.content.body")
    {:ok, ["event", "content", "body"]}
    iex> RadioBeam.AccessExtras.property_string_to_path("event.content.m\\\\.federate")
    {:ok, ["event", "content", "m.federate"]}
    iex> RadioBeam.AccessExtras.property_string_to_path("event.content.body" <> <<0>>)
    {:error, :invalid_key}
  """
  def property_string_to_path(property_string) do
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
end
