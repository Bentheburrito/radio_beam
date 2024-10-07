defmodule Fixtures do
  @moduledoc """
  Test fixtures
  """

  alias Polyjuice.Util.Identifiers.V1.UserIdentifier
  alias RadioBeam.ContentRepo.Upload.FileInfo
  alias RadioBeam.ContentRepo
  alias RadioBeam.Device
  alias RadioBeam.User
  alias Vix.Vips.Operation

  def strong_password, do: "Asdf123$"

  def user(user_id \\ "localhost" |> UserIdentifier.generate() |> to_string()) do
    {:ok, user} = User.new(user_id, strong_password())
    Memento.transaction!(fn -> Memento.Query.write(user) end)
  end

  def device(user_id, display_name \\ Device.default_device_name()) do
    device = Device.new(user_id, display_name: display_name)
    Memento.transaction!(fn -> Device.persist(device) end)
  end

  def write!(%Device{} = device), do: Memento.transaction!(fn -> Device.persist(device) end)
  def write!(struct), do: Memento.transaction!(fn -> Memento.Query.write(struct) end)

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
end
