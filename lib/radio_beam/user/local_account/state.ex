defmodule RadioBeam.User.LocalAccount.State do
  @moduledoc """
  A description of a user account's locked or suspended state.
  """
  @attrs ~w|state_name changed_by_id changed_at effective_until|a
  @enforce_keys @attrs
  defstruct @attrs

  @type state_name() :: :unrestricted | :locked | :suspended
  @state_names ~w|unrestricted locked suspended|a

  def new!(state_name, changed_by_id, opts \\ []) when state_name in @state_names do
    changed_at = Keyword.get_lazy(opts, :changed_at, fn -> DateTime.utc_now() end)
    effective_until = Keyword.get(opts, :effective_until, :infinity)

    %__MODULE__{
      state_name: state_name,
      changed_by_id: changed_by_id,
      changed_at: changed_at,
      effective_until: effective_until
    }
  end
end
