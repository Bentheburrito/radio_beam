defmodule Fixtures do
  @moduledoc """
  Test fixtures
  """

  alias RadioBeam.Room
  alias Polyjuice.Util.Identifiers.V1.UserIdentifier
  alias RadioBeam.ContentRepo.Upload.FileInfo
  alias RadioBeam.ContentRepo
  alias RadioBeam.Device
  alias RadioBeam.User
  alias Vix.Vips.Operation

  def strong_password, do: "Asdf123$"

  def user(user_id \\ "localhost" |> UserIdentifier.generate() |> to_string()) do
    {:ok, user} = User.new(user_id, strong_password())
    :ok = User.put_new(user)
    user
  end

  def device(user_id, display_name \\ Device.default_device_name()) do
    {:ok, %{access_token: at}} = User.Auth.login(user_id, Device.generate_token(), display_name)
    {:ok, device} = Device.get_by_access_token(at)
    device
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

  def send_text_msg(room_id, user_id, message, content_overrides \\ %{}) do
    content = Map.merge(%{"msgtype" => "m.text", "body" => message}, content_overrides)
    Room.send(room_id, user_id, "m.room.message", content)
  end

  def create_cross_signing_keys(user_id) do
    master_key_id = "base64masterpublickey"
    {master_pubkey, master_privkey} = :crypto.generate_key(:eddsa, :ed25519)

    master_key = %{
      "keys" => %{("ed25519:" <> master_key_id) => Base.encode64(master_pubkey, padding: false)},
      "usage" => ["master"],
      "user_id" => user_id
    }

    master_signingkey =
      Polyjuice.Util.Ed25519.SigningKey.from_base64(Base.encode64(master_privkey, padding: false), master_key_id)

    {:ok, self_signing_key} =
      Polyjuice.Util.JSON.sign(
        %{
          "keys" => %{
            "ed25519:base64selfsigningpublickey" =>
              Base.encode64("base64+self+signing+master+public+key", padding: false)
          },
          "usage" => ["self_signing"],
          "user_id" => user_id
        },
        user_id,
        master_signingkey
      )

    {:ok, user_signing_key} =
      Polyjuice.Util.JSON.sign(
        %{
          "keys" => %{
            "ed25519:base64usersigningpublickey" =>
              Base.encode64("base64+user+signing+master+public+key", padding: false)
          },
          "usage" => ["user_signing"],
          "user_id" => user_id
        },
        user_id,
        master_signingkey
      )

    [
      master_key: master_key,
      self_signing_key: self_signing_key,
      user_signing_key: user_signing_key
    ]
  end

  def device_keys(id, user_id) do
    %{
      "algorithms" => [
        "m.olm.v1.curve25519-aes-sha2",
        "m.megolm.v1.aes-sha2"
      ],
      "device_id" => id,
      "keys" => %{
        "curve25519:#{id}" => "curve_key",
        "ed25519:#{id}" => "ed_key"
      },
      "signatures" => %{
        user_id => %{
          "ed25519:#{id}" => "dSO80A01XiigH3uBiDVx/EjzaoycHcjq9lfQX0uWsqxl2giMIiSPR8a4d291W1ihKJL/a+myXS367WT6NAIcBA"
        }
      },
      "user_id" => user_id
    }
  end
end
