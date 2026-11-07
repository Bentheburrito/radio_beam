defmodule RadioBeam do
  @moduledoc """
  RadioBeam keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """
  use Boundary,
    deps: [Argon2, Ecto, Guardian, Hammer, Phoenix.PubSub, Polyjuice.Util],
    exports: [
      AccessExtras,
      Admin,
      ContentRepo,
      ContentRepo.MatrixContentURI,
      Errors,
      RateLimit,
      Room,
      Room.Alias,
      Room.EphemeralState,
      Room.Timeline,
      Room.Timeline.Acknowledgements,
      Sync,
      Time,
      Transaction,
      User,
      User.Authentication,
      User.Authentication.ClientServerRequest,
      User.Authentication.LegacyAPI,
      User.Authentication.OAuth2,
      User.EventFilter,
      User.ID,
      User.KeyStore,
      User.RoomMemberships
    ]

  alias RadioBeam.Config
  alias RadioBeam.Room.Timeline.LazyLoadMembersCache

  def application_children do
    :ok = RadioBeam.Database.init()

    [
      {DNSCluster, query: Application.get_env(:radio_beam, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: RadioBeam.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: RadioBeam.Finch},
      # Start the EventHandler Registry
      {Registry, keys: :unique, name: RadioBeam.EventHandler.Server.registry()},
      # Start the RoomRegistry
      {Registry, keys: :unique, name: RadioBeam.RoomRegistry},
      # Start the RoomEphemeralStateRegistry
      {Registry, keys: :unique, name: RadioBeam.RoomEphemeralStateRegistry},
      # Start the RoomAcknowledgementsRegistry
      {Registry, keys: :unique, name: RadioBeam.RoomAcknowledgementsRegistry},
      # Start the SyncSinkRegistry
      {Registry, keys: :unique, name: RadioBeam.Sync.SinkRegistry},
      # Start the EventHandler DynamicSupervisor
      RadioBeam.EventHandler.Server.Supervisor,
      # Start the GenServer that handles transaction IDs
      RadioBeam.Transaction,
      # Start the Room.Server.Supervisor
      RadioBeam.Room.Server.Supervisor,
      # Start the Room.EphemeralState.Server Supervisor
      RadioBeam.Room.EphemeralState.Server.Supervisor,
      # Start the Room.EphemeralState.Server Supervisor
      RadioBeam.Room.Timeline.Acknowledgements.Server.Supervisor,
      # Start the Sync.SinkServer.Supervisor
      RadioBeam.Sync.SinkServer.Supervisor,
      # Start the Sync Source Task.Supervisor
      {Task.Supervisor, name: RadioBeam.Sync.Source.Supervisor},
      # PubSub listener to update user notifications based on read receipt updates
      RadioBeam.User.Notifications.ReadMarkerServer,
      # Cache to reduce redundant membership events in /sync
      LazyLoadMembersCache,
      # Cache for authorization code grant flow state
      RadioBeam.User.Authentication.OAuth2.Builtin.AuthzCodeCache,
      # Start the Hammer rate limiter
      RadioBeam.RateLimit
    ]
  end

  def config_change(_changed, _new, _removed) do
    :ok
  end

  def local_homeservers, do: Config.local_homeservers()

  def lookup_server_name(delegated_host) do
    case Enum.find(RadioBeam.local_homeservers(), &(&1.delegated_host == delegated_host)) do
      %{server_display_name: server_name} -> {:ok, server_name}
      nil -> {:error, :not_found}
    end
  end

  def lookup_delegated_host(server_name) do
    case Enum.find(RadioBeam.local_homeservers(), &(&1.server_display_name == server_name)) do
      %{delegated_host: host} -> {:ok, host}
      nil -> {:error, :not_found}
    end
  end

  def admins(server_name), do: Config.admins(server_name)

  def supported_room_versions, do: Config.supported_room_versions()
  def default_room_version, do: Config.default_room_version()
  def max_timeline_events, do: Config.max_timeline_events()
  def max_state_events, do: Config.max_state_events()
end
