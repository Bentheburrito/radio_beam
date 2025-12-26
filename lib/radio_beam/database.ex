defmodule RadioBeam.Database do
  @moduledoc """
  A behaviour for implementing a persistence backend. RadioBeam includes the
  `RadioBeam.Database.Mnesia` backend out of the box.

  The backend must support executing multiple database operations in the
  context of a transaction. This is accomplished via the `c:transaction/1`
  callback, whose argument is a 0-arity function which contains database writes
  that should be considered one atomic action.
  """

  @callback init() :: :ok | {:error, String.t()}

  @database_backend Application.compile_env!(:radio_beam, [RadioBeam.Database, :backend])
  defdelegate init, to: @database_backend
end
