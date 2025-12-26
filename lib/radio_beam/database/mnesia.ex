defmodule RadioBeam.Database.Mnesia do
  @moduledoc """
  A database backend for `:mnesia`
  """
  @behaviour RadioBeam.Database
  @behaviour RadioBeam.ContentRepo.Database
  @behaviour RadioBeam.Room.Database

  import RadioBeam.Database.Mnesia.Tables.User
  import RadioBeam.Database.Mnesia.Tables.Room
  import RadioBeam.Database.Mnesia.Tables.RoomAlias
  import RadioBeam.Database.Mnesia.Tables.Upload
  import RadioBeam.Database.Mnesia.Tables.RoomView
  import RadioBeam.Database.Mnesia.Tables.DynamicOAuth2Client

  alias RadioBeam.ContentRepo.Upload
  alias RadioBeam.Database.Mnesia.Tables
  alias RadioBeam.Room
  alias RadioBeam.Room.View
  alias RadioBeam.User
  alias RadioBeam.User.Authentication.OAuth2.Builtin.DynamicOAuth2Client

  require Logger

  @tables [Tables.User, Tables.Room, Tables.RoomAlias, Tables.Upload, Tables.RoomView, Tables.DynamicOAuth2Client]

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

  @impl RadioBeam.Database
  def transaction(fxn) do
    if :mnesia.is_transaction() do
      fxn.()
    else
      case :mnesia.transaction(fxn) do
        {:atomic, result} -> result
        {:aborted, error} -> {:error, error}
      end
    end
  end

  defp transaction!(fxn) do
    case transaction(fxn) do
      :ok -> :ok
      {:ok, result} -> result
      {:error, error} -> raise error
      result -> result
    end
  end

  @impl RadioBeam.Database
  def insert(data, opts) do
    data_record = domain_struct_to_record(data)
    table = elem(data_record, 0)

    lock_type = Keyword.get(opts, :lock, :write)
    transaction(fn -> :mnesia.write(table, data_record, lock_type) end)
  end

  @impl RadioBeam.Database
  def insert!(data, opts) do
    data_record = domain_struct_to_record(data)
    table = elem(data_record, 0)

    lock_type = Keyword.get(opts, :lock, :write)
    transaction!(fn -> :mnesia.write(table, data_record, lock_type) end)
  end

  @impl RadioBeam.Database
  def insert_new(data, opts) do
    data_record = domain_struct_to_record(data)
    table = elem(data_record, 0)

    lock_type = Keyword.get(opts, :lock, :write)

    transaction(fn ->
      if exists?(table, data.id, lock_type) do
        {:error, :already_exists}
      else
        :mnesia.write(table, data_record, lock_type)
      end
    end)
  end

  defp exists?(table, id, lock_type) do
    table |> :mnesia.read(id, lock_type) |> Enum.empty?() |> Kernel.not()
  end

  @impl RadioBeam.Database
  def fetch(data_mod, id, opts \\ []) do
    table = domain_mod_to_table(data_mod)
    lock_type = Keyword.get(opts, :lock, :read)

    transaction(fn ->
      case :mnesia.read(table, id, lock_type) do
        [] -> {:error, :not_found}
        [record] -> {:ok, record_to_domain_struct(record)}
      end
    end)
  end

  @impl RadioBeam.Database
  def fetch!(data_mod, id, opts) do
    table = domain_mod_to_table(data_mod)
    lock_type = Keyword.get(opts, :lock, :read)

    transaction!(fn ->
      case :mnesia.read(table, id, lock_type) do
        [] -> {:error, :not_found}
        [record] -> {:ok, record_to_domain_struct(record)}
      end
    end)
  end

  @impl RadioBeam.Database
  def get_all(_data_mod, [], _opts), do: []

  def get_all(data_mod, ids, opts) when is_list(ids) do
    table = domain_mod_to_table(data_mod)
    lock_type = Keyword.get(opts, :lock, :read)

    transaction(fn ->
      case :mnesia.select(table, get_all_match_spec(table, ids), lock_type) do
        matched_records when is_list(matched_records) -> Enum.map(matched_records, &record_to_domain_struct/1)
      end
    end)
  end

  defp get_all_match_spec(table, ids) do
    match_head_fxn =
      case table do
        Tables.User -> &user(id: &1, user: :_)
        Tables.Room -> &room(id: &1, room: :_)
        Tables.RoomAlias -> &room_alias(alias_struct: &1, room_id: :_)
        Tables.RoomView -> &room_view(id: &1, room_view: :_)
        Tables.DynamicOAuth2Client -> &dynamic_oauth2_client(id: &1, dynamic_oauth2_client: :_)
      end

    _match_functions =
      for id <- ids, do: {match_head_fxn.(id), [], [:"$_"]}
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

  defp domain_struct_to_record(%User{} = user), do: user(id: user.id, user: user)

  defp domain_struct_to_record(%DynamicOAuth2Client{} = dyn_oauth2_client),
    do: dynamic_oauth2_client(id: dyn_oauth2_client.client_id, dynamic_oauth2_client: dyn_oauth2_client)

  defp record_to_domain_struct(user(user: %User{} = user)), do: user
  defp record_to_domain_struct(room(room: %Room{} = room)), do: room
  defp record_to_domain_struct(room_alias(alias_struct: %Room.Alias{} = room_alias)), do: room_alias
  defp record_to_domain_struct(upload() = upload_record), do: struct!(Upload, upload(upload_record))

  defp record_to_domain_struct(room_view(room_view: view_state)), do: view_state

  defp record_to_domain_struct(
         dynamic_oauth2_client(dynamic_oauth2_client: %DynamicOAuth2Client{} = dyn_oauth2_client)
       ),
       do: dyn_oauth2_client

  defp domain_mod_to_table(User), do: Tables.User
  defp domain_mod_to_table(Room), do: Tables.Room
  defp domain_mod_to_table(Room.Alias), do: Tables.RoomAlias
  defp domain_mod_to_table(View.State), do: Tables.RoomView
  defp domain_mod_to_table(DynamicOAuth2Client), do: Tables.DynamicOAuth2Client
end
