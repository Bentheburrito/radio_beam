defmodule RadioBeam.Room.State do
  @moduledoc """
  The state events in a Matrix room.
  """
  @type t() :: term()

  @callback new!() :: t()
  @callback authorize_event(t(), event_attrs :: map()) ::
              {:ok, AuthorizedEvent.t()} | {:error, :unauthorized | :could_not_compute_reference_hash}
  @callback room_version(t()) :: String.t()
  @callback size(t()) :: non_neg_integer()
  @callback fetch(t(), String.t()) :: {:ok, PDU.t()} | {:error, :not_found}
  @callback fetch(t(), String.t(), String.t()) :: {:ok, PDU.t()} | {:error, :not_found}
  @callback fetch_at(t(), String.t(), String.t(), PDU.t()) :: {:ok, PDU.t()} | {:error, :not_found}
  @callback get_all(t()) :: map()
  @callback get_all_at(t(), PDU.t()) :: map()
  @callback replace_pdu!(t(), PDU.t()) :: t()
  @callback handle_pdu(t(), PDU.t()) :: t()

  alias Polyjuice.Util.RoomVersion
  alias RadioBeam.Room.PDU

  def authorize_event(%state_backend{} = state, event_attrs), do: state_backend.authorize_event(state, event_attrs)

  def room_version(%state_backend{} = state), do: state_backend.room_version(state)

  def size(%state_backend{} = state), do: state_backend.size(state)

  def fetch(%state_backend{} = state, type, state_key \\ ""), do: state_backend.fetch(state, type, state_key)

  def fetch_at(%state_backend{} = state, type, state_key \\ "", %PDU{} = pdu),
    do: state_backend.fetch_at(state, type, state_key, pdu)

  def get_all(%state_backend{} = state), do: state_backend.get_all(state)
  def get_all_at(%state_backend{} = state, %PDU{} = pdu), do: state_backend.get_all_at(state, pdu)

  def replace_pdu!(%state_backend{} = state, %PDU{} = pdu), do: state_backend.replace_pdu!(state, pdu)

  def handle_pdu(%state_backend{} = state, %PDU{} = pdu), do: state_backend.handle_pdu(state, pdu)

  @stripped_state_types Enum.map(~w|create name avatar topic join_rules canonical_alias encryption|, &"m.room.#{&1}")
  @doc "Returns the stripped state of the given room."
  def get_invite_state_pdus(state, user_id) do
    # we additionally include the calling user's membership event

    @stripped_state_types
    |> Stream.map(&{&1, ""})
    |> Stream.concat([{"m.room.member", user_id}])
    |> Enum.reduce([], fn {type, state_key}, acc ->
      case fetch(state, type, state_key) do
        {:ok, pdu} -> [pdu | acc]
        {:error, :not_found} -> acc
      end
    end)
  end

  def user_has_power?(state, power_level_content_path, user_id, state_event? \\ false) do
    # TODO: Polyjuice RoomState protocol
    state_mapping = get_all(state)
    room_version = room_version(state)
    RoomVersion.has_power?(room_version, user_id, power_level_content_path, state_event?, state_mapping)
  end
end
