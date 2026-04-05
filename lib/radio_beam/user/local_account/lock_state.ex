defmodule RadioBeam.User.LocalAccount.LockState do
  @moduledoc """
  A description of a user account's locked state.
  """
  @attrs ~w|locked_by_id locked_at locked_until|a
  @enforce_keys @attrs
  defstruct @attrs

  def new!(locked_by_id, opts \\ []) do
    locked_at = Keyword.get_lazy(opts, :locked_at, fn -> DateTime.utc_now() end)
    locked_until = Keyword.get(opts, :locked_until, :infinity)

    %__MODULE__{locked_by_id: locked_by_id, locked_at: locked_at, locked_until: locked_until}
  end
end
