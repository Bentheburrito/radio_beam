defmodule RadioBeamWeb.AdminController do
  use RadioBeamWeb, :controller

  import RadioBeamWeb.Utils, only: [json_error: 4, ip_tuple_to_string: 1]

  alias RadioBeam.Admin
  alias RadioBeam.User

  require Logger

  plug RadioBeamWeb.Plugs.EnforceSchema,
       [mod: RadioBeamWeb.Schemas.Admin] when action not in [:whois, :check_account_lock, :check_account_suspension]

  @already_reported_msg "You have already reported this content."
  @not_found_msg "The event was not found or you are not joined to the room."

  def report_room(conn, %{"room_id" => room_id}) do
    user_id = conn.assigns.user_id
    reason = conn.assigns.request["reason"]

    case Admin.report_room(room_id, user_id, reason) do
      {:ok, _} -> json(conn, %{})
      {:error, :not_found} -> json_error(conn, 404, :not_found, "Room not found")
      {:error, :already_exists} -> json_error(conn, 403, :forbidden, @already_reported_msg)
    end
  end

  def report_room_event(conn, %{"room_id" => room_id, "event_id" => event_id}) do
    user_id = conn.assigns.user_id
    reason = conn.assigns.request["reason"]

    case Admin.report_room_event(room_id, event_id, user_id, reason) do
      {:ok, _} -> json(conn, %{})
      {:error, :not_found} -> json_error(conn, 404, :not_found, @not_found_msg)
      {:error, :not_a_member} -> json_error(conn, 404, :not_found, @not_found_msg)
      {:error, :already_exists} -> json_error(conn, 403, :forbidden, @already_reported_msg)
    end
  end

  def report_user(conn, %{"user_id" => reported_user_id}) do
    user_id = conn.assigns.user_id
    reason = conn.assigns.request["reason"]

    case Admin.report_user(reported_user_id, user_id, reason) do
      {:ok, _} -> json(conn, %{})
      {:error, :not_found} -> json_error(conn, 404, :not_found, "User not found")
      {:error, :already_exists} -> json_error(conn, 403, :forbidden, @already_reported_msg)
    end
  end

  def change_account_lock(conn, %{"user_id" => user_id}) do
    admin_id = conn.assigns.user_id
    apply_lock? = conn.assigns.request["locked"]

    lock_result =
      if apply_lock?,
        do: Admin.lock_account(user_id, admin_id),
        else: Admin.remove_account_restrictions(user_id, admin_id)

    case lock_result do
      {:ok, _account} -> json(conn, %{locked: apply_lock?})
      {:error, :unauthorized} -> json_error(conn, 403, :forbidden, "Unauthorized")
      {:error, :not_found} -> json_error(conn, 404, :not_found, "User is non-local, doesn't exist, or was deactivated")
    end
  end

  def check_account_lock(conn, %{"user_id" => user_id}) do
    admin_id = conn.assigns.user_id

    case Admin.get_account_locked_status(user_id, admin_id) do
      {:locked?, locked?} when is_boolean(locked?) -> json(conn, %{locked: locked?})
      {:error, :unauthorized} -> json_error(conn, 403, :forbidden, "Unauthorized")
      {:error, :not_found} -> json_error(conn, 404, :not_found, "User is non-local, doesn't exist, or was deactivated")
    end
  end

  def change_account_suspension(conn, %{"user_id" => user_id}) do
    admin_id = conn.assigns.user_id
    apply_suspension? = conn.assigns.request["suspended"]

    suspend_result =
      if apply_suspension?,
        do: Admin.suspend_account(user_id, admin_id),
        else: Admin.remove_account_restrictions(user_id, admin_id)

    case suspend_result do
      {:ok, _account} -> json(conn, %{suspended: apply_suspension?})
      {:error, :unauthorized} -> json_error(conn, 403, :forbidden, "Unauthorized")
      {:error, :not_found} -> json_error(conn, 404, :not_found, "User is non-local, doesn't exist, or was deactivated")
    end
  end

  def check_account_suspension(conn, %{"user_id" => user_id}) do
    admin_id = conn.assigns.user_id

    case Admin.get_account_suspended_status(user_id, admin_id) do
      {:suspended?, suspended?} when is_boolean(suspended?) -> json(conn, %{suspended: suspended?})
      {:error, :unauthorized} -> json_error(conn, 403, :forbidden, "Unauthorized")
      {:error, :not_found} -> json_error(conn, 404, :not_found, "User is non-local, doesn't exist, or was deactivated")
    end
  end

  @not_found_msg "user not found, or you don't have permission to view information via this endpoint."
  def whois(%{assigns: %{user_id: user_id}} = conn, %{"user_id" => target_id}) do
    if user_id in RadioBeam.admins() and User.exists?(target_id) do
      case User.get_all_device_info(target_id) do
        device_info when is_list(device_info) ->
          json(conn, %{user_id: target_id, devices: device_sessions(device_info)})
      end
    else
      json_error(conn, 404, :not_found, @not_found_msg)
    end
  end

  def whois(conn, _params), do: json_error(conn, 404, :not_found, @not_found_msg)

  defp device_sessions(device_info) do
    Map.new(
      device_info,
      &{&1.display_name,
       %{
         sessions: [
           %{
             connections: [
               %{last_seen: &1.last_seen_at, ip: ip_tuple_to_string(&1.last_seen_from_ip), user_agent: "unknown"}
             ]
           }
         ]
       }}
    )
  end
end
