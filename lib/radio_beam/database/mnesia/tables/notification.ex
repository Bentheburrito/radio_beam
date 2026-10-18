defmodule RadioBeam.Database.Mnesia.Tables.Notification do
  @moduledoc false

  require Record
  Record.defrecord(:notification, __MODULE__, key: nil, notification: nil)

  @type t() :: record(:notification, key: {User.id(), non_neg_integer()}, notification: RadioBeam.User.Notification.t())

  def opts, do: [attributes: notification() |> notification() |> Keyword.keys(), type: :ordered_set]
end
