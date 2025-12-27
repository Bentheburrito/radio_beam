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
      ContentRepo,
      ContentRepo.MatrixContentURI,
      Errors,
      PubSub,
      RateLimit,
      Room,
      Room.Alias,
      Room.EphemeralState,
      Room.Timeline,
      Sync,
      Transaction,
      User,
      User.Account,
      User.Authentication.OAuth2,
      User.Authentication.LegacyAPI,
      User.EventFilter,
      User.Keys,
      ### temp / leaky
      ContentRepo.Database,
      ContentRepo.Thumbnail,
      ContentRepo.Upload,
      ContentRepo.Upload.FileInfo,
      Room.Events.PaginationToken,
      User.Authentication.OAuth2.UserDeviceSession,
      User.CrossSigningKeyRing,
      User.Device,
      User.Device.Message,
      User.Device.OneTimeKeyRing,
      User.RoomKeys,
      User.RoomKeys.Backup,
      User.RoomKeys.Backup.KeyData
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
      # Start the RoomRegistry
      {Registry, keys: :unique, name: RadioBeam.RoomRegistry},
      # Start the RoomEphemeralStateRegistry
      {Registry, keys: :unique, name: RadioBeam.RoomEphemeralStateRegistry},
      # Start the GenServer that handles transaction IDs
      RadioBeam.Transaction,
      # Start the Room.Server.Supervisor
      RadioBeam.Room.Server.Supervisor,
      # Start the Room.EphemeralState.Server Supervisor
      RadioBeam.Room.EphemeralState.Server.Supervisor,
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

  def server_name, do: Config.server_name()
  def admins, do: Config.admins()

  def supported_room_versions, do: Config.supported_room_versions()
  def default_room_version, do: Config.default_room_version()
  def max_timeline_events, do: Config.max_timeline_events()
  def max_state_events, do: Config.max_state_events()
end
