defmodule RadioBeam.Database do
  @moduledoc """
  A behaviour for implementing a persistence backend. RadioBeam includes the
  `RadioBeam.Database.Mnesia` backend out of the box.

  The backend must support executing multiple database operations in the
  context of a transaction. This is accomplished via the `c:transaction/1`
  callback, whose argument is a 0-arity function which contains database writes
  that should be considered one atomic action.
  """
  alias RadioBeam.ContentRepo.Upload
  alias RadioBeam.Room
  alias RadioBeam.Room.View
  alias RadioBeam.User
  alias RadioBeam.User.Authentication.OAuth2.Builtin.DynamicOAuth2Client

  @type reason() :: String.t()
  @type transaction_result() :: :ok | {:error, :not_found | reason()}
  @type data() ::
          User.t()
          | Room.t()
          | Upload.t()
          | DynamicOAuth2Client.t()
          | View.State.t()
  @type data_module() :: User | Room | Upload | DynamicOAuth2Client | Participating | RelatedEvents | Timeline
  @type id() :: term()

  @callback init() :: :ok | {:error, reason()}
  @callback transaction((-> transaction_result())) :: transaction_result()

  @callback insert(data(), Keyword.t()) :: :ok | {:error, reason()}
  @callback insert!(data(), Keyword.t()) :: :ok
  @callback insert_new(data(), Keyword.t()) :: :ok | {:error, :already_exists | reason()}
  @callback fetch(data_module(), id(), Keyword.t()) :: {:ok, data()} | {:error, reason()}
  @callback fetch!(data_module(), id(), Keyword.t()) :: data()
  @callback get_all(data_module(), [id()], Keyword.t()) :: {:ok, [data()]} | {:error, reason()}

  @database_backend Application.compile_env!(:radio_beam, [RadioBeam.Database, :backend])
  defdelegate init, to: @database_backend
  defdelegate transaction(fxn), to: @database_backend
  defdelegate insert(data, opts), to: @database_backend
  defdelegate insert!(data, opts), to: @database_backend
  defdelegate insert_new(data, opts), to: @database_backend
  defdelegate fetch(data_module, id, opts), to: @database_backend
  defdelegate fetch!(data_module, id, opts), to: @database_backend
  defdelegate get_all(data_module, ids, opts), to: @database_backend

  def insert(data), do: @database_backend.insert(data, [])
  def insert!(data), do: @database_backend.insert!(data, [])
  def insert_new(data), do: @database_backend.insert_new(data, [])
  def fetch(data_module, id), do: @database_backend.fetch(data_module, id, [])
  def fetch!(data_module, id), do: @database_backend.fetch!(data_module, id, [])
  def get_all(data_module, ids), do: @database_backend.get_all(data_module, ids, [])
end
