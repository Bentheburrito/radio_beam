defmodule RadioBeam.Repo do
  # use Ecto.Repo,
  #   otp_app: :radio_beam,
  #   adapter: Ecto.Adapters.Postgres

  require Logger

  alias RadioBeam.ContentRepo.Upload
  alias RadioBeam.Device
  alias RadioBeam.Room.Timeline.Filter
  alias RadioBeam.PDU
  alias RadioBeam.Room
  alias RadioBeam.User

  @doc """
  Initializes Mnesia schema for the given list of nodes (defaults to `[node()]`.

  Stops the `:mnesia` application in order to create the schema.
  """
  def init_mnesia(nodes \\ [node()]) do
    # Create the schema
    Memento.stop()

    case Memento.Schema.create(nodes) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.info("init_mnesia(#{inspect(nodes)}): Failed to create schema: #{inspect(reason)}")
    end

    Memento.start()

    create_tables(nodes)
  end

  @tables [User, Device, PDU.Table, Room, Room.Alias, Filter, Upload]
  defp create_tables(nodes) do
    # don't persist DB ops to disk for tests - clean DB every run of `mix test`
    opts =
      if RadioBeam.env() == :test do
        [ram_copies: nodes]
      else
        [disc_copies: nodes]
      end

    for table <- @tables, do: create_table(table, opts)
    Memento.wait(@tables)
  end

  defp create_table(table_mod, opts) when is_atom(table_mod) and is_list(opts) do
    case Memento.Table.create(table_mod, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.info("create_table(#{table_mod}, #{inspect(opts)}): Failed to create table: #{inspect(reason)}")
    end
  end
end
