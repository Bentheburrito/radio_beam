defmodule RadioBeam.Admin.Database do
  @moduledoc """
  A behaviour for implementing a persistence backend for the `RadioBeam.Admin`
  bounded context.
  """
  alias RadioBeam.Admin.UserGeneratedReport

  @callback insert_new_report(UserGeneratedReport.t()) :: :ok | {:error, :already_exists}
  @callback all_reports() :: [UserGeneratedReport.t()]

  @database_backend Application.compile_env!(:radio_beam, [RadioBeam.Admin.Database, :backend])
  defdelegate insert_new_report(report), to: @database_backend
  defdelegate all_reports, to: @database_backend
end
