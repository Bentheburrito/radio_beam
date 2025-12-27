defmodule RadioBeam.Database.Mnesia do
  @moduledoc """
  A database backend for `:mnesia`
  """
  @behaviour RadioBeam.Database
  @behaviour RadioBeam.ContentRepo.Database
  @behaviour RadioBeam.Room.Database
  @behaviour RadioBeam.User.Database

  import RadioBeam.Database.Mnesia.Tables.User
  import RadioBeam.Database.Mnesia.Tables.LocalAccount
  import RadioBeam.Database.Mnesia.Tables.Room
  import RadioBeam.Database.Mnesia.Tables.RoomAlias
  import RadioBeam.Database.Mnesia.Tables.Upload
  import RadioBeam.Database.Mnesia.Tables.RoomView
  import RadioBeam.Database.Mnesia.Tables.DynamicOAuth2Client

  alias RadioBeam.ContentRepo.Upload
  alias RadioBeam.Database.Mnesia.Tables
  alias RadioBeam.Room
  alias RadioBeam.User
  alias RadioBeam.User.LocalAccount
  alias RadioBeam.User.Authentication.OAuth2.Builtin.DynamicOAuth2Client

  require Logger

  @tables [
    Tables.User,
    Tables.LocalAccount,
    Tables.Room,
    Tables.RoomAlias,
    Tables.Upload,
    Tables.RoomView,
    Tables.DynamicOAuth2Client
  ]

  @impl RadioBeam.Database
  def init do
    Logger.info("Initializing :mnesia...")

    :mnesia.stop()

    nodes = [node()]

    case :mnesia.create_schema(nodes) do
      :ok -> :ok
      {:error, {_node1, {:already_exists, _node2}}} -> :ok
      {:error, reason} -> Logger.error("init_mnesia(#{inspect(nodes)}): Failed to create schema: #{inspect(reason)}")
    end

    :mnesia.start()

    create_tables(nodes)
  end

  @copy_type if Mix.env() == :test, do: :ram_copies, else: :disc_copies
  defp create_tables(nodes) do
    # don't persist DB ops to disk for tests - clean DB every run of `mix test`
    default_table_opts = [{@copy_type, nodes}]

    for table <- @tables, do: create_table(table, Keyword.merge(default_table_opts, table.opts()))
    :mnesia.wait_for_tables(@tables, :infinity)
  end

  defp create_table(table_mod, opts) when is_atom(table_mod) and is_list(opts) do
    case :mnesia.create_table(table_mod, opts) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, ^table_mod}} -> :ok
      {:aborted, reason} -> Logger.error("Failed to create table #{inspect(table_mod)}: #{inspect(reason)}")
    end
  end

  defp transaction(fxn) do
    if :mnesia.is_transaction() do
      fxn.()
    else
      case :mnesia.transaction(fxn) do
        {:atomic, result} -> result
        {:aborted, error} -> {:error, error}
      end
    end
  end

  @impl RadioBeam.Room.Database
  def upsert_room(%Room{} = room) do
    room_record = room(id: room.id, room: room)

    transaction(fn ->
      :mnesia.write(Tables.Room, room_record, :write)
    end)
  end

  @impl RadioBeam.Room.Database
  def fetch_room(room_id) do
    transaction(fn ->
      case :mnesia.read(Tables.Room, room_id, :read) do
        [] -> {:error, :not_found}
        [record] -> {:ok, record_to_domain_struct(record)}
      end
    end)
  end

  @impl RadioBeam.Room.Database
  def upsert_view(key, view) do
    room_view_record = room_view(id: key, room_view: view)

    transaction(fn ->
      :mnesia.write(Tables.RoomView, room_view_record, :write)
    end)
  end

  @impl RadioBeam.Room.Database
  def fetch_view(key) do
    transaction(fn ->
      case :mnesia.read(Tables.RoomView, key, :read) do
        [] -> {:error, :not_found}
        [record] -> {:ok, record_to_domain_struct(record)}
      end
    end)
  end

  @impl RadioBeam.Room.Database
  def create_alias(%Room.Alias{} = alias, room_id, ensure_room_exists? \\ true) do
    transaction(fn ->
      case :mnesia.read(Tables.RoomAlias, alias, :write) do
        [_record] ->
          {:error, :alias_in_use}

        [] ->
          if ensure_room_exists? do
            case :mnesia.read(Tables.Room, room_id, :read) do
              [room(id: ^room_id)] -> [alias_struct: alias, room_id: room_id] |> room_alias() |> :mnesia.write()
              [] -> {:error, :room_does_not_exist}
            end
          else
            [alias_struct: alias, room_id: room_id] |> room_alias() |> :mnesia.write()
          end
      end
    end)
  end

  @impl RadioBeam.Room.Database
  def fetch_room_id_by_alias(%Room.Alias{} = alias) do
    transaction(fn ->
      case :mnesia.read(Tables.RoomAlias, alias, :read) do
        [] -> {:error, :not_found}
        [room_alias(room_id: room_id)] -> {:ok, room_id}
      end
    end)
  end

  @impl RadioBeam.ContentRepo.Database
  def upsert_upload(%Upload{} = upload) do
    data_record =
      upload(id: upload.id, file: upload.file, inserted_at: upload.inserted_at, uploaded_by_id: upload.uploaded_by_id)

    transaction(fn -> :mnesia.write(Tables.Upload, data_record, :write) end)
  end

  @impl RadioBeam.ContentRepo.Database
  def fetch_upload(mxc) do
    transaction(fn ->
      case :mnesia.read(Tables.Upload, mxc, :read) do
        [] -> {:error, :not_found}
        [record] -> {:ok, record_to_domain_struct(record)}
      end
    end)
  end

  @impl RadioBeam.ContentRepo.Database
  def with_user_total_uploaded_bytes("@" <> _ = uploaded_by_id, callback) do
    match_head = upload(id: :_, file: :"$1", inserted_at: :_, uploaded_by_id: uploaded_by_id)
    match_spec = [{match_head, [{:is_map, :"$1"}], [:"$1"]}]

    transaction(fn ->
      Tables.Upload
      |> :mnesia.select(match_spec)
      |> Stream.map(& &1.byte_size)
      |> Enum.sum()
      |> callback.()
    end)
  end

  @impl RadioBeam.ContentRepo.Database
  def with_user_upload_counts("@" <> _ = uploaded_by_id, callback) do
    match_head = upload(id: :_, file: :"$1", inserted_at: :_, uploaded_by_id: uploaded_by_id)
    match_spec = [{match_head, [], [:"$1"]}]

    transaction(fn ->
      Tables.Upload
      |> :mnesia.select(match_spec)
      |> Enum.reduce(%{}, fn
        :reserved, acc -> Map.update(acc, :reserved, 1, &(&1 + 1))
        %Upload.FileInfo{}, acc -> Map.update(acc, :uploaded, 1, &(&1 + 1))
      end)
      |> callback.()
    end)
  end

  @impl RadioBeam.User.Database
  def insert_new_user(%User{} = user) do
    user_record = user(id: user.id, user: user)

    transaction(fn ->
      if user_exists?(user.id), do: {:error, :already_exists}, else: :mnesia.write(Tables.User, user_record, :write)
    end)
  end

  defp user_exists?(id), do: Tables.User |> :mnesia.read(id, :write) |> Enum.empty?() |> Kernel.not()

  @impl RadioBeam.User.Database
  def insert_new_user_account(%LocalAccount{} = account) do
    record = local_account(id: account.user_id, local_account: account)

    transaction(fn ->
      if account_exists?(account.user_id),
        do: {:error, :already_exists},
        else: :mnesia.write(Tables.LocalAccount, record, :write)
    end)
  end

  defp account_exists?(id), do: Tables.LocalAccount |> :mnesia.read(id, :write) |> Enum.empty?() |> Kernel.not()

  @impl RadioBeam.User.Database
  def update_user(%User{id: user_id} = user) do
    transaction(fn ->
      case :mnesia.read(Tables.User, user.id, :write) do
        [] -> {:error, :not_found}
        [user(id: ^user_id)] -> :mnesia.write(Tables.User, user(id: user.id, user: user), :write)
      end
    end)
  end

  @impl RadioBeam.User.Database
  def upsert_oauth2_client(%DynamicOAuth2Client{client_id: client_id} = client) do
    data_record = dynamic_oauth2_client(id: client_id, dynamic_oauth2_client: client)

    transaction(fn -> :mnesia.write(Tables.DynamicOAuth2Client, data_record, :write) end)
  end

  @impl RadioBeam.User.Database
  def fetch_oauth2_client(client_id) do
    transaction(fn ->
      case :mnesia.read(Tables.DynamicOAuth2Client, client_id, :read) do
        [] -> {:error, :not_found}
        [record] -> {:ok, record_to_domain_struct(record)}
      end
    end)
  end

  @impl RadioBeam.User.Database
  def fetch_user(user_id) do
    transaction(fn ->
      case :mnesia.read(Tables.User, user_id, :read) do
        [] -> {:error, :not_found}
        [record] -> {:ok, record_to_domain_struct(record)}
      end
    end)
  end

  @impl RadioBeam.User.Database
  def fetch_user_account(user_id) do
    transaction(fn ->
      case :mnesia.read(Tables.LocalAccount, user_id, :read) do
        [] -> {:error, :not_found}
        [record] -> {:ok, record_to_domain_struct(record)}
      end
    end)
  end

  @impl RadioBeam.User.Database
  def with_user(user_id, callback) do
    transaction(fn ->
      case :mnesia.read(Tables.User, user_id, :write) do
        [] -> {:error, :not_found}
        [record] -> record |> record_to_domain_struct() |> callback.()
      end
    end)
  end

  @impl RadioBeam.User.Database
  def with_all_users([], callback), do: callback.([])

  def with_all_users(user_ids, callback) when is_list(user_ids) do
    match_spec = for id <- user_ids, do: {user(id: id, user: :_), [], [:"$_"]}

    transaction(fn ->
      case :mnesia.select(Tables.User, match_spec, :write) do
        matched_records when is_list(matched_records) ->
          callback.(Enum.map(matched_records, &record_to_domain_struct/1))
      end
    end)
  end

  @impl RadioBeam.User.Database
  def txn(callback) do
    transaction(callback)
  end

  defp record_to_domain_struct(user(user: %User{} = user)), do: user
  defp record_to_domain_struct(local_account(local_account: %LocalAccount{} = account)), do: account
  defp record_to_domain_struct(room(room: %Room{} = room)), do: room
  defp record_to_domain_struct(room_alias(alias_struct: %Room.Alias{} = room_alias)), do: room_alias
  defp record_to_domain_struct(upload() = upload_record), do: struct!(Upload, upload(upload_record))

  defp record_to_domain_struct(room_view(room_view: view_state)), do: view_state

  defp record_to_domain_struct(
         dynamic_oauth2_client(dynamic_oauth2_client: %DynamicOAuth2Client{} = dyn_oauth2_client)
       ),
       do: dyn_oauth2_client
end
