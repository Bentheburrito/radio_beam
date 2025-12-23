defmodule Fixtures do
  @moduledoc """
  Test fixtures
  """

  alias Polyjuice.Util.Identifiers.V1.UserIdentifier
  alias RadioBeam.Repo
  alias RadioBeam.Room
  alias RadioBeam.Room.Events
  alias RadioBeam.Room.AuthorizedEvent
  alias RadioBeam.ContentRepo.Upload.FileInfo
  alias RadioBeam.ContentRepo
  alias RadioBeam.User
  alias RadioBeam.User.Device
  alias Vix.Vips.Operation

  def strong_password, do: "Asdf123$"

  def device_id, do: 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  def room_id(server_name \\ "localhost"),
    do: server_name |> Polyjuice.Util.Identifiers.V1.RoomIdentifier.generate() |> to_string()

  def room(version \\ "11", creator_id \\ user_id(), deps \\ default_room_deps(), opts \\ []) do
    {room, _pdus} = Room.Core.new(version, creator_id, deps, opts)
    room
  end

  defp default_room_deps do
    %{
      register_room_alias: fn
        "#invalid:localhost", _ -> {:error, :invalid_alias}
        "#not_mapped:localhost", _ -> :ok
        _alias, _ -> {:error, :already_registered}
      end
    }
  end

  def send_room_event(room, sender_id, type, content, deps \\ default_room_deps()) do
    event_attrs = Events.message(room.id, sender_id, type, content)
    Room.Core.send(room, event_attrs, deps)
  end

  def send_room_msg(room, sender_id, msg, deps \\ default_room_deps()) do
    event_attrs = Events.message(room.id, sender_id, "m.room.message", %{"msgtype" => "m.text", "body" => msg})
    Room.Core.send(room, event_attrs, deps)
  end

  def send_room_membership(room, sender_id, target_id, membership, deps \\ default_room_deps()) do
    event_attrs = Events.membership(room.id, sender_id, target_id, membership)
    Room.Core.send(room, event_attrs, deps)
  end

  def make_room_view(view_module, room) do
    all_pdus = make_room_view_pdus(room.dag)

    view_state = view_module.new!()

    Enum.reduce(all_pdus, view_state, fn pdu, view_state ->
      case view_module.handle_pdu(view_state, room, pdu) do
        {view_state, _pubsub} -> view_state
        view_state -> view_state
      end
    end)
  end

  defp make_room_view_pdus(dag) do
    make_room_view_pdus(dag, Room.DAG.forward_extremities(dag), [])
  end

  defp make_room_view_pdus(dag, next_event_ids, pdus) do
    new_pdus = for event_id <- next_event_ids, do: Room.DAG.fetch!(dag, event_id)

    if match?([], new_pdus) do
      Enum.sort_by(pdus, & &1.stream_number, :asc)
    else
      make_room_view_pdus(dag, new_pdus |> Stream.flat_map(& &1.prev_event_ids) |> Stream.uniq(), new_pdus ++ pdus)
    end
  end

  def user_id(server_name \\ "localhost"), do: server_name |> UserIdentifier.generate() |> to_string()

  def user(user_id \\ user_id()) do
    {:ok, user} = User.new(user_id, strong_password())
    {:ok, user} = RadioBeam.Repo.insert(user)
    user
  end

  def device(user_or_user_id, display_name \\ Device.default_device_name())

  def device("@" <> _ = user_id, display_name) do
    {:ok, user} = RadioBeam.Repo.fetch(User, user_id)
    device(user, display_name)
  end

  def device(user, display_name) do
    device_id = device_id()

    %{user: user, device: device} =
      RadioBeam.User.Authentication.OAuth2.UserDeviceSession.new_from_user!(user, device_id, display_name: display_name)

    {user, device}
  end

  def file_info(content, type \\ "txt", filename \\ "TestUpload") do
    FileInfo.new(type, byte_size(content), :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower), filename)
  end

  def random_string(num_bytes) do
    for _i <- 1..num_bytes, into: "", do: <<:rand.uniform(26) + ?A - 1>>
  end

  def jpg_upload(user, width, height, tmp_dir, repo_dir \\ ContentRepo.path()) do
    {:ok, upload} = ContentRepo.create(user)

    tmp_upload_path = Path.join([tmp_dir, "tmp_jpg_upload_#{width}_#{height}"])

    {text, _} =
      Operation.text!(
        ~s(<span foreground="blue">This is a <b>thumbnail</b> with </span> <span foreground="red">rendered text</span>),
        dpi: 300,
        rgba: true
      )

    width
    |> Operation.black!(height)
    |> Operation.composite2!(text, :VIPS_BLEND_MODE_OVER, x: 20, y: div(height, 4))
    |> Operation.jpegsave!(tmp_upload_path)

    file_info = file_info(File.read!(tmp_upload_path), "jpg", "cool_picture")
    {:ok, upload} = ContentRepo.upload(upload, file_info, tmp_upload_path, repo_dir)
    upload
  end

  def create_cross_signing_keys(user_id) do
    {master_pubkey, master_privkey} = :crypto.generate_key(:eddsa, :ed25519)
    {user_pubkey, user_privkey} = :crypto.generate_key(:eddsa, :ed25519)
    {self_pubkey, self_privkey} = :crypto.generate_key(:eddsa, :ed25519)

    master_pubkeyb64 = Base.encode64(master_pubkey, padding: false)
    user_pubkeyb64 = Base.encode64(user_pubkey, padding: false)
    self_pubkeyb64 = Base.encode64(self_pubkey, padding: false)

    master_key = %{
      "keys" => %{"ed25519:#{master_pubkeyb64}" => master_pubkeyb64},
      "usage" => ["master"],
      "user_id" => user_id
    }

    master_signingkey =
      Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(master_privkey, padding: false), master_pubkeyb64)

    {:ok, self_signing_key} =
      Polyjuice.Util.JSON.sign(
        %{
          "keys" => %{"ed25519:#{self_pubkeyb64}" => self_pubkeyb64},
          "usage" => ["self_signing"],
          "user_id" => user_id
        },
        user_id,
        master_signingkey
      )

    {:ok, user_signing_key} =
      Polyjuice.Util.JSON.sign(
        %{
          "keys" => %{"ed25519:#{user_pubkeyb64}" => user_pubkeyb64},
          "usage" => ["user_signing"],
          "user_id" => user_id
        },
        user_id,
        master_signingkey
      )

    {[
       master_key: master_key,
       self_signing_key: self_signing_key,
       user_signing_key: user_signing_key
     ], _priv_keys = %{master_key: master_privkey, self_key: self_privkey, user_key: user_privkey}}
  end

  def device_keys(id, user_id) do
    {pubkey, privkey} = :crypto.generate_key(:eddsa, :ed25519)
    pubkeyb64 = Base.encode64(pubkey, padding: false)

    signingkey = Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(privkey, padding: false), id)

    {:ok, signed_key_obj} =
      Polyjuice.Util.JSON.sign(
        %{
          "algorithms" => [
            "m.olm.v1.curve25519-aes-sha2",
            "m.megolm.v1.aes-sha2"
          ],
          "device_id" => id,
          "keys" => %{
            # "curve25519:#{id}" => "curve_key",
            "ed25519:#{id}" => pubkeyb64
          },
          "signatures" => %{},
          "user_id" => user_id
        },
        user_id,
        signingkey
      )

    {signed_key_obj, signingkey}
  end

  def create_and_put_device_keys(user, device) do
    {key, _} = device_keys(device.id, user.id)
    {:ok, device} = Device.put_keys(device, user.id, identity_keys: key)
    {:ok, user} = user |> User.put_device(device) |> Repo.insert()
    {user, device}
  end

  def authz_event(event_attrs, auth_events) do
    attrs = Map.put(event_attrs, "auth_events", auth_events)

    {:ok, id} = Events.reference_hash(attrs, "11")

    attrs
    |> Map.put("id", id)
    |> AuthorizedEvent.new!()
  end

  def authz_create_event(sender_id \\ user_id(), content_overrides \\ %{}) do
    room_id()
    |> Events.create(sender_id, "11", content_overrides)
    |> authz_event([])
  end

  def authz_message_event(room_id, sender_id, auth_events, message) do
    room_id
    |> Events.text_message(sender_id, message)
    |> authz_event(auth_events)
  end
end
