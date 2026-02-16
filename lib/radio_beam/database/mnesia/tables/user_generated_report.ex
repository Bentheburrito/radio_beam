defmodule RadioBeam.Database.Mnesia.Tables.UserGeneratedReport do
  @moduledoc false

  alias RadioBeam.Admin.UserGeneratedReport
  alias RadioBeam.User

  require Record
  Record.defrecord(:user_generated_report, __MODULE__, target_and_submitted_by: nil, created_at: nil, reason: nil)

  @type t() ::
          record(:user_generated_report,
            target_and_submitted_by: {UserGeneratedReport.target(), User.id()},
            created_at: DateTime.t(),
            reason: String.t() | nil
          )

  def opts,
    do: [attributes: user_generated_report() |> user_generated_report() |> Keyword.keys(), type: :set, index: []]
end
