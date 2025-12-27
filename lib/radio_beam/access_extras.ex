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
end
