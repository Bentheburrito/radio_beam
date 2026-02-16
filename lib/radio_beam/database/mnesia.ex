defmodule RadioBeam.Database.Mnesia do
  @moduledoc """
  A database backend for `:mnesia`
  """
  @behaviour RadioBeam.Database

  @behaviour RadioBeam.Admin.Database
  @behaviour RadioBeam.ContentRepo.Database
  @behaviour RadioBeam.Room.Database
  @behaviour RadioBeam.User.Database

  import RadioBeam.Database.Mnesia.Tables.Device
  import RadioBeam.Database.Mnesia.Tables.DynamicOAuth2Client
  import RadioBeam.Database.Mnesia.Tables.KeyStore
  import RadioBeam.Database.Mnesia.Tables.LocalAccount
  import RadioBeam.Database.Mnesia.Tables.Room
  import RadioBeam.Database.Mnesia.Tables.RoomAlias
  import RadioBeam.Database.Mnesia.Tables.RoomView
  import RadioBeam.Database.Mnesia.Tables.Upload
  import RadioBeam.Database.Mnesia.Tables.UserClientConfig
  import RadioBeam.Database.Mnesia.Tables.UserGeneratedReport

  alias RadioBeam.Admin.UserGeneratedReport
  alias RadioBeam.ContentRepo.Upload
  alias RadioBeam.Database.Mnesia.Tables
  alias RadioBeam.Room
  alias RadioBeam.User.Authentication.OAuth2.Builtin.DynamicOAuth2Client
  alias RadioBeam.User.ClientConfig
  alias RadioBeam.User.Device
  alias RadioBeam.User.KeyStore
  alias RadioBeam.User.LocalAccount

  require Logger

  @tables [
    Tables.Device,
    Tables.DynamicOAuth2Client,
    Tables.KeyStore,
    Tables.LocalAccount,
    Tables.Room,
    Tables.RoomAlias,
    Tables.RoomView,
    Tables.Upload,
    Tables.UserClientConfig,
    Tables.UserGeneratedReport
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
      upload(id: upload.id, file: upload.file, created_at: upload.created_at, uploaded_by_id: upload.uploaded_by_id)

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
    match_head = upload(id: :_, file: :"$1", created_at: :_, uploaded_by_id: uploaded_by_id)
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
    match_head = upload(id: :_, file: :"$1", created_at: :_, uploaded_by_id: uploaded_by_id)
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
  def insert_new_device(%Device{} = device) do
    device_record = device(user_device_id_tuple: {device.user_id, device.id}, device: device)

    transaction(fn ->
      if device_exists?(device.user_id, device.id),
        do: {:error, :already_exists},
        else: :mnesia.write(Tables.Device, device_record, :write)
    end)
  end

  defp device_exists?(user_id, device_id),
    do: Tables.Device |> :mnesia.read({user_id, device_id}, :write) |> Enum.empty?() |> Kernel.not()

  @impl RadioBeam.User.Database
  def update_user_device_with(user_id, device_id, callback) do
    transaction(fn ->
      case :mnesia.read(Tables.Device, {user_id, device_id}, :write) do
        [device(user_device_id_tuple: {^user_id, ^device_id}) = device_record] ->
          device_record |> record_to_domain_struct() |> callback.() |> map_update_result()

        [] ->
          {:error, :not_found}
      end
    end)
  end

  defp map_update_result({:ok, %Device{} = device, return_value}) do
    write_device(device)
    {:ok, return_value}
  end

  defp map_update_result(%Device{} = device), do: {:ok, write_device(device)}
  defp map_update_result({:ok, %Device{} = device}), do: {:ok, write_device(device)}
  defp map_update_result({:error, error}), do: {:error, error}

  defp write_device(device) do
    :ok =
      :mnesia.write(Tables.Device, device(user_device_id_tuple: {device.user_id, device.id}, device: device), :write)

    device
  end

  @impl RadioBeam.User.Database
  def fetch_user_device(user_id, device_id) do
    transaction(fn ->
      case :mnesia.read(Tables.Device, {user_id, device_id}, :read) do
        [] -> {:error, :not_found}
        [device(user_device_id_tuple: {^user_id, _}) = record] -> {:ok, record_to_domain_struct(record)}
        [_record] -> {:error, :not_found}
      end
    end)
  end

  @impl RadioBeam.User.Database
  def get_all_devices_of_user(user_id) do
    match_spec = [{device(user_device_id_tuple: {user_id, :_}, device: :_), [], [:"$_"]}]

    transaction(fn ->
      case :mnesia.select(Tables.Device, match_spec, :write) do
        matched_records when is_list(matched_records) -> Enum.map(matched_records, &record_to_domain_struct/1)
      end
    end)
  end

  @impl RadioBeam.User.Database
  def upsert_user_client_config_with(user_id, callback) do
    transaction(fn ->
      current_client_config =
        case :mnesia.read(Tables.UserClientConfig, user_id, :write) do
          [] -> ClientConfig.new!(user_id)
          [user_client_config(user_id: ^user_id) = data_record] -> record_to_domain_struct(data_record)
        end

      case callback.(current_client_config) do
        {:ok, %ClientConfig{} = new_client_config} -> write_client_config(new_client_config, user_id)
        %ClientConfig{} = new_client_config -> write_client_config(new_client_config, user_id)
        error -> error
      end
    end)
  end

  defp write_client_config(%ClientConfig{} = config, user_id) do
    data_record = user_client_config(user_id: user_id, client_config: config)
    :mnesia.write(Tables.UserClientConfig, data_record, :write)
    {:ok, config}
  end

  @impl RadioBeam.User.Database
  def fetch_user_client_config(user_id) do
    transaction(fn ->
      case :mnesia.read(Tables.UserClientConfig, user_id, :read) do
        [] -> {:error, :not_found}
        [record] -> {:ok, record_to_domain_struct(record)}
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
  def fetch_user_account(user_id) do
    transaction(fn ->
      case :mnesia.read(Tables.LocalAccount, user_id, :read) do
        [] -> {:error, :not_found}
        [record] -> {:ok, record_to_domain_struct(record)}
      end
    end)
  end

  @impl RadioBeam.User.Database
  def fetch_key_store(user_id) do
    transaction(fn ->
      case :mnesia.read(Tables.KeyStore, user_id, :read) do
        [] -> {:error, :not_found}
        [record] -> {:ok, record_to_domain_struct(record)}
      end
    end)
  end

  @impl RadioBeam.User.Database
  def insert_new_key_store(user_id, %KeyStore{} = key_store) do
    key_store_record = key_store(user_id: user_id, key_store: key_store)

    transaction(fn ->
      if key_store_exists?(user_id),
        do: {:error, :already_exists},
        else: :mnesia.write(Tables.KeyStore, key_store_record, :write)
    end)
  end

  defp key_store_exists?(id), do: Tables.KeyStore |> :mnesia.read(id, :write) |> Enum.empty?() |> Kernel.not()

  @impl RadioBeam.User.Database
  def update_key_store(user_id, callback) do
    transaction(fn ->
      case :mnesia.read(Tables.KeyStore, user_id, :write) do
        [] ->
          {:error, :not_found}

        [key_store(user_id: ^user_id) = record] ->
          case record |> record_to_domain_struct() |> callback.() do
            %KeyStore{} = key_store ->
              :mnesia.write(Tables.KeyStore, key_store(user_id: user_id, key_store: key_store), :write)
              {:ok, key_store}

            {:ok, %KeyStore{} = key_store} ->
              :mnesia.write(Tables.KeyStore, key_store(user_id: user_id, key_store: key_store), :write)
              {:ok, key_store}

            error ->
              error
          end
      end
    end)
  end

  @impl RadioBeam.Admin.Database
  def insert_new_report(%UserGeneratedReport{} = report) do
    key = {report.target, report.submitted_by}

    report = user_generated_report(target_and_submitted_by: key, created_at: report.created_at, reason: report.reason)

    transaction(fn ->
      if report_exists?(key),
        do: {:error, :already_exists},
        else: :mnesia.write(Tables.UserGeneratedReport, report, :write)
    end)
  end

  defp report_exists?(key), do: Tables.UserGeneratedReport |> :mnesia.read(key, :write) |> Enum.empty?() |> Kernel.not()

  @impl RadioBeam.Admin.Database
  def all_reports do
    match_head = user_generated_report(target_and_submitted_by: :_, created_at: :_, reason: :_)
    match_spec = [{match_head, [], [:"$_"]}]

    transaction(fn ->
      Tables.UserGeneratedReport |> :mnesia.select(match_spec) |> Enum.map(&record_to_domain_struct/1)
    end)
  end

  defp record_to_domain_struct(key_store(key_store: %KeyStore{} = key_store)), do: key_store
  defp record_to_domain_struct(user_client_config(client_config: %ClientConfig{} = config)), do: config
  defp record_to_domain_struct(device(device: %Device{} = device)), do: device
  defp record_to_domain_struct(local_account(local_account: %LocalAccount{} = account)), do: account
  defp record_to_domain_struct(room(room: %Room{} = room)), do: room
  defp record_to_domain_struct(room_alias(alias_struct: %Room.Alias{} = room_alias)), do: room_alias
  defp record_to_domain_struct(upload() = upload_record), do: struct!(Upload, upload(upload_record))
  defp record_to_domain_struct(room_view(room_view: view_state)), do: view_state

  defp record_to_domain_struct(
         dynamic_oauth2_client(dynamic_oauth2_client: %DynamicOAuth2Client{} = dyn_oauth2_client)
       ),
       do: dyn_oauth2_client

  defp record_to_domain_struct(
         user_generated_report(target_and_submitted_by: {target, submitted_by}, created_at: created_at, reason: reason)
       ) do
    {:ok, report} = UserGeneratedReport.new(target, submitted_by, created_at, reason)
    report
  end
end
