defmodule RadioBeam.User.RoomMemberships do
  @moduledoc """
  Tracks a user's membership across rooms using m.room.member events.
  """
  @behaviour RadioBeam.EventHandler

  alias RadioBeam.User.Database
  alias RadioBeam.Room.PDU

  defstruct room_ids_to_membership: %{}
  @type t() :: %__MODULE__{}

  def new!, do: %__MODULE__{}

  @doc "Returns all room IDs that `user_id` is joined to"
  @spec joined(RadioBeam.User.id()) :: [String.t()]
  def joined(user_id) do
    %__MODULE__{} = memberships = fetch!(user_id)
    for {room_id, "join"} <- memberships.room_ids_to_membership, do: room_id
  end

  @doc "Returns all room IDs that `user_id` is invited to"
  @spec invited(RadioBeam.User.id()) :: [String.t()]
  def invited(user_id) do
    %__MODULE__{} = memberships = fetch!(user_id)
    for {room_id, "invite"} <- memberships.room_ids_to_membership, do: room_id
  end

  @doc "Returns all room IDs that `user_id` is or was joined to"
  @spec joined_now_or_previously(RadioBeam.User.id()) :: [String.t()]
  def joined_now_or_previously(user_id) do
    %__MODULE__{} = memberships = fetch!(user_id)
    for {room_id, membership} when membership in ~w|join leave| <- memberships.room_ids_to_membership, do: room_id
  end

  @doc """
  Returns `true` if the given user has any kind of `m.room.member` event in
  `room_id`.
  """
  @spec has?(RadioBeam.User.id(), RadioBeam.Room.id()) :: boolean()
  def has?(user_id, room_id),
    do: user_id |> fetch!() |> Map.fetch!(:room_ids_to_membership) |> is_map_key(room_id)

  def fetch(user_id, room_id) do
    %__MODULE__{} = memberships = fetch!(user_id)
    with :error <- Map.fetch(memberships.room_ids_to_membership, room_id), do: {:error, :not_found}
  end

  defp fetch!(user_id) do
    case Database.fetch_user_room_memberships(user_id) do
      {:ok, %__MODULE__{} = relations} -> relations
      {:error, :not_found} -> new!()
    end
  end

  @impl RadioBeam.EventHandler
  def handle_pdu(%PDU{event: %{type: "m.room.member", state_key: "@" <> _}} = pdu, _) do
    user_id = pdu.event.state_key
    memberships = fetch!(user_id)

    memberships = put_in(memberships.room_ids_to_membership[pdu.event.room_id], pdu.event.content["membership"])

    Database.upsert_user_room_memberships(user_id, memberships)
  end

  def handle_pdu(%PDU{}, _), do: :ok

  @impl RadioBeam.EventHandler
  # depending on how far back the EventHandler is telling us to reset to, the
  # `RoomMemberships` reads may be inconsistent/old for a time. Once it catches
  # back up, it should be fine. We may consider recording the last known stream
  # #s for each room, and then "hiding"/locking the main row while the handler
  # is behind. Updates can be applied to some kind of staging/temporary row
  # (perhaps in the same table under a diff key, or a separate table
  # altogether).
  #
  # anyway, all that is adding quite a lot of complexity to avoid a situation
  # that is (again, hopefully) very brief, so we're just going to
  # optimistically reset and reapply events for now.
  def reset_to(event_number), do: {:ok, event_number}
end
