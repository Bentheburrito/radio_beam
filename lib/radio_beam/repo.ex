defmodule RadioBeam.Repo do
  # use Ecto.Repo,
  #   otp_app: :radio_beam,
  #   adapter: Ecto.Adapters.Postgres

  require Logger

  alias RadioBeam.{User, Device}

  @doc """
  Initializes Mnesia schema for the given list of nodes (defaults to `[node()]`.

  Stops the `:mnesia` application in order to create the schema.
  """
  def init_mnesia(nodes \\ [node()]) do
    # Create the schema
    Memento.stop()

    case Memento.Schema.create(nodes) do
      :ok -> :ok
      {:error, reason} -> Logger.info("init_mnesia(#{inspect(nodes)}): Failed to create schema: #{inspect(reason)}")
    end

    Memento.start()

    # Create your tables with disc_copies (only the ones you want persisted on disk)
    create_tables(nodes)
  end

  defp create_tables(nodes) do
    create_table(User, disc_copies: nodes)
    create_table(Device, disc_copies: nodes)
  end

  defp create_table(table_mod, opts) when is_atom(table_mod) and is_list(opts) do
    case Memento.Table.create(table_mod, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.info("create_table(#{table_mod}, #{inspect(opts)}): Failed to create table: #{inspect(reason)}")
    end
  end

  ### CRUD helper fxns ###

  @type table_struct :: User.t() | Device.t()
  @type table_module :: User | Device

  @spec insert(table_struct()) :: {:ok, table_struct()}
  def insert(record) do
    Memento.transaction(fn -> Memento.Query.write(record) end)
  end

  @spec insert!(table_struct()) :: {:ok, table_struct()}
  def insert!(record) do
    Memento.transaction!(fn -> Memento.Query.write(record) end)
  end

  @spec get(table_module(), id :: any()) :: {:ok, table_struct() | nil}
  def get(module, id) do
    Memento.transaction(fn -> Memento.Query.read(module, id) end)
  end

  @spec delete(table_module(), id :: any()) :: :ok
  def delete(module, id) do
    Memento.transaction(fn -> Memento.Query.delete(module, id) end)

    :ok
  end
end
