defmodule RadioBeam.Repo do
  # use Ecto.Repo,
  #   otp_app: :radio_beam,
  #   adapter: Ecto.Adapters.Postgres

  require Logger

  alias RadioBeam.ContentRepo.Upload
  alias RadioBeam.Room
  alias RadioBeam.Repo.Tables
  alias RadioBeam.User

  @doc """
  Initializes Mnesia schema for the given list of nodes (defaults to `[node()]`.

  Stops the `:mnesia` application in order to create the schema.
  """
  def init_mnesia(nodes \\ [node()]) do
    # Create the schema
    Memento.stop()

    with {:error, reason} <- Memento.Schema.create(nodes) do
      Logger.info("init_mnesia(#{inspect(nodes)}): Failed to create schema: #{inspect(reason)}")
    end

    Memento.start()

    create_tables(nodes)
  end

  @tables [User, Tables.Room, Room.Alias, Upload, Tables.ViewState]
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
    with {:error, reason} <- Memento.Table.create(table_mod, opts) do
      Logger.info("create_table(#{table_mod}, #{inspect(opts)}): Failed to create table: #{inspect(reason)}")
    end
  end

  @doc """
  Execute the given function inside a `Memento`/`:mnesia` transaction if one
  has not been started already.
  """
  @spec transaction(function()) :: any()
  def transaction(fxn) do
    if Memento.Transaction.inside?() do
      fxn.()
    else
      case Memento.transaction(fxn) do
        :ok -> :ok
        {:ok, result} -> result
        {:error, {:transaction_aborted, error}} -> {:error, error}
        {:error, error} -> raise "Repo.transaction error: #{Exception.format(:error, error)}"
      end
    end
  end

  @doc "Same as transaction/1, except raises on error"
  @spec transaction!(function()) :: any()
  def transaction!(fxn) do
    case transaction(fxn) do
      {:ok, result} -> result
      {:error, error} -> raise error
      result -> result
    end
  end

  @spec fetch(table :: module(), id :: any(), opts :: Keyword.t()) :: {:ok, struct()} | {:error, :not_found}
  def fetch(table, id, opts \\ [])

  def fetch(table, id, opts) when table in @tables do
    transaction(fn ->
      case Memento.Query.read(table, id, opts) do
        nil -> {:error, :not_found}
        data -> {:ok, table.load!(data)}
      end
    end)
  end

  def get_all(table, ids, opts \\ [])

  def get_all(table, ids, opts) when table in @tables do
    transaction(fn ->
      Enum.reduce(ids, [], fn id, acc ->
        case fetch(table, id, opts) do
          {:error, :not_found} -> acc
          {:ok, data} -> [table.load!(data) | acc]
        end
      end)
    end)
  end

  def insert(%table{} = data) when table in @tables do
    transaction(fn -> {:ok, data |> table.dump!() |> Memento.Query.write()} end)
  end

  def insert!(%table{} = data) do
    transaction!(fn -> data |> table.dump!() |> Memento.Query.write() end)
  end

  def insert_new(%table{} = data) when table in @tables do
    transaction(fn ->
      case fetch(table, data.id, lock: :write) do
        {:ok, %^table{}} -> {:error, :already_exists}
        {:error, :not_found} -> {:ok, data |> table.dump!() |> Memento.Query.write()}
      end
    end)
  end

  def delete(table, key) when table in @tables do
    transaction(fn -> Memento.Query.delete(table, key) end)
  end

  def delete(%table{} = data) when table in @tables do
    transaction(fn -> data |> table.dump!() |> Memento.Query.delete_record() end)
  end

  def select(table, match_spec, opts \\ [])

  def select(table, match_spec, opts) when table in @tables do
    transaction(fn -> Memento.Query.select_raw(table, match_spec, opts) end)
  end
end
