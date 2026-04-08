defmodule RadioBeamWeb.Schemas.Admin do
  @moduledoc false

  def report_room, do: %{"reason" => [:string, :optional]}
  def report_room_event, do: %{"reason" => [:string, :optional]}
  def report_user, do: %{"reason" => [:string, :optional]}

  def change_account_lock, do: %{"locked" => :boolean}
  def change_account_suspension, do: %{"suspended" => :boolean}
end
