defmodule RadioBeam.Admin do
  @moduledoc """
  Functions for performing administrator actions, or reporting content to
  server admins
  """
  alias RadioBeam.Admin.Database
  alias RadioBeam.Admin.UserGeneratedReport
  alias RadioBeam.Config
  alias RadioBeam.Room
  alias RadioBeam.User
  alias RadioBeam.User.LocalAccount

  require Logger

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

  ### USER ACCOUNT MANAGEMENT ###

  @doc """
  Lock a user's account, preventing them from using it.

  If `lock_until` is provided, it should be the `t:DateTime` after which the
  account will unlock automatically. Defaults to `:infinity`.
  """
  def lock_account(user_id, admin_id, lock_until \\ :infinity) do
    opts = [effective_until: lock_until]

    with :ok <- validate_admin(admin_id),
         :ok <- validate_lockable_user(user_id) do
      User.update_local_account(user_id, &LocalAccount.lock(&1, admin_id, opts))
    end
  end

  def unlock_account(user_id, admin_id) do
    opts = [effective_until: DateTime.utc_now()]

    with :ok <- validate_admin(admin_id) do
      User.update_local_account(user_id, &LocalAccount.remove_restrictions(&1, admin_id, opts))
    end
  end

  defp validate_lockable_user(user_id) do
    if user_id in Config.admins(), do: {:error, :unauthorized}, else: :ok
  end

  def get_account_locked_status(user_id, admin_id) do
    with :ok <- validate_admin(admin_id),
         :ok <- validate_user_exists(user_id) do
      {:locked?, User.account_locked?(user_id)}
    end
  end

  defp validate_admin(user_id) do
    if user_id in Config.admins() do
      :ok
    else
      Logger.error("non-admin #{inspect(user_id)} tried to take an action")
      {:error, :unauthorized}
    end
  end
end
