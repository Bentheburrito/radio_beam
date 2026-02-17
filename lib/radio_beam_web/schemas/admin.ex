defmodule RadioBeamWeb.Schemas.Admin do
  @moduledoc false

  def report_room, do: %{"reason" => [:string, :optional]}
  def report_room_event, do: %{"reason" => [:string, :optional]}
  def report_user, do: %{"reason" => [:string, :optional]}
end
