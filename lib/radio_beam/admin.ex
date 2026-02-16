defmodule RadioBeam.Admin do
  @moduledoc """
  Functions for performing administrator actions, or reporting content to
  server admins
  """
  alias RadioBeam.Admin.Database
  alias RadioBeam.Admin.UserGeneratedReport
  alias RadioBeam.Room
  alias RadioBeam.User

  ### ABUSE / CONTENT REPORTING ###

  def report_user(target_id, submitter_id, reason) do
    with :ok <- validate_user_exists(submitter_id),
         :ok <- validate_user_exists(target_id),
         {:ok, %UserGeneratedReport{} = report} <- new_report(target_id, submitter_id, reason),
         :ok <- Database.insert_new_report(report) do
      {:ok, report}
    end
  end

  defp validate_user_exists(user_id) do
    if User.exists?(user_id), do: :ok, else: {:error, :not_found}
  end

  defp new_report(target, submitter, reason), do: UserGeneratedReport.new(target, submitter, DateTime.utc_now(), reason)

  def report_room(room_id, submitter_id, reason) do
    with :ok <- validate_user_exists(submitter_id),
         :ok <- validate_room_exists(room_id),
         {:ok, %UserGeneratedReport{} = report} <- new_report(room_id, submitter_id, reason),
         :ok <- Database.insert_new_report(report) do
      {:ok, report}
    end
  end

  defp validate_room_exists(room_id) do
    if Room.exists?(room_id), do: :ok, else: {:error, :not_found}
  end

  def report_room_event(room_id, event_id, submitter_id, reason) do
    with :ok <- validate_user_exists(submitter_id),
         :ok <- validate_room_exists(room_id),
         :ok <- validate_membership(room_id, submitter_id),
         :ok <- validate_event_exists(room_id, submitter_id, event_id),
         {:ok, %UserGeneratedReport{} = report} <- new_report({room_id, event_id}, submitter_id, reason),
         :ok <- Database.insert_new_report(report) do
      {:ok, report}
    end
  end

  defp validate_event_exists(room_id, user_id, event_id) do
    if match?({:ok, %{id: ^event_id}}, Room.get_event(room_id, user_id, event_id)), do: :ok, else: {:error, :not_found}
  end

  defp validate_membership(room_id, submitter_id) do
    if room_id in Room.joined(submitter_id), do: :ok, else: {:error, :not_a_member}
  end

  def all_reports, do: Database.all_reports()
end
