defmodule RadioBeam.Room.Chronicle do
  @moduledoc """
  A chronicle of known events and state in a Matrix room.
  """

  alias RadioBeam.Room
  alias RadioBeam.Room.AuthorizedEvent
  alias RadioBeam.Room.PDU

  @type t() :: term()

  @typep state_event_mapping() :: %{{String.t(), String.t()} => AuthorizedEvent.t()}
  @typep state_mapping() :: %{{String.t(), String.t()} => Room.event_id()}

  @callback new!(create_event_attrs :: map(), dag_backend_mod :: module()) :: {t(), AuthorizedEvent.t()}
  @callback room_id(t()) :: Room.id()
  @callback room_version(t()) :: String.t()
  @callback get_create_event(t()) :: AuthorizedEvent.t()

  @callback try_append(t(), event_attrs :: map()) ::
              {:ok, AuthorizedEvent.t()} | {:error, :unauthorized | :could_not_compute_reference_hash}

  @callback get_state_event_mapping_before(t(), Room.event_id()) :: {:ok, state_event_mapping()} | {:error, :not_found}

  @callback get_state_mapping(t(), Room.event_id(), boolean()) :: {:ok, state_mapping()} | {:error, :not_found}
  @callback get_state_mapping(t(), Room.event_id()) :: {:ok, state_mapping()} | {:error, :not_found}
  @callback get_state_mapping(t()) :: state_mapping()

  @callback fetch_event(t(), Room.event_id()) :: {:ok, AuthorizedEvent.t()} | {:error, :not_found}
  @callback fetch_pdu!(t(), Room.event_id()) :: PDU.t()
  @callback replace!(t(), AuthorizedEvent.t()) :: t()

  def room_id(%chronicle_backend{} = chronicle), do: chronicle_backend.room_id(chronicle)
  def room_version(%chronicle_backend{} = chronicle), do: chronicle_backend.room_version(chronicle)
  def get_create_event(%chronicle_backend{} = chronicle), do: chronicle_backend.get_create_event(chronicle)

  def try_append(%chronicle_backend{} = chronicle, event_attrs),
    do: chronicle_backend.try_append(chronicle, event_attrs)

  def get_state_event_mapping_before(%chronicle_backend{} = chronicle, event_id),
    do: chronicle_backend.get_state_event_mapping_before(chronicle, event_id)

  def get_state_mapping(%chronicle_backend{} = chronicle, event_id \\ :current_state, apply_event_ids? \\ false),
    do: chronicle_backend.get_state_mapping(chronicle, event_id, apply_event_ids?)

  def fetch_event(%chronicle_backend{} = chronicle, event_id), do: chronicle_backend.fetch_event(chronicle, event_id)
  def fetch_pdu!(%chronicle_backend{} = chronicle, event_id), do: chronicle_backend.fetch_pdu!(chronicle, event_id)

  def replace!(%chronicle_backend{} = chronicle, %AuthorizedEvent{} = event),
    do: chronicle_backend.replace!(chronicle, event)
end
