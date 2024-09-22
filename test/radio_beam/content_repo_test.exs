defmodule RadioBeam.ContentRepoTest do
  use ExUnit.Case, async: true

  alias RadioBeam.ContentRepo
  alias RadioBeam.ContentRepo.MatrixContentURI
  alias RadioBeam.ContentRepo.Upload

  defp random_string(num_bytes) do
    for _i <- 1..num_bytes, into: "", do: <<:rand.uniform(26) + ?A - 1>>
  end

  describe "save_upload/3" do
    setup do
      user = Fixtures.user()
      iodata = random_string(20)
      {:ok, mxc} = MatrixContentURI.new()
      %Upload{} = upload = Upload.new(mxc, "image/jpg", user, iodata)
      %{upload: upload, iodata: iodata, user: user}
    end

    @tag :tmp_dir
    test "successfully saves a user's first upload", %{tmp_dir: tmp_dir, upload: upload, iodata: iodata} do
      assert {:ok, upload_path} = ContentRepo.save_upload(upload, iodata, tmp_dir)
      assert IO.iodata_to_binary(iodata) == File.read!(upload_path)
      assert {:ok, ^upload} = Upload.get(upload.id)
    end

    @tag :tmp_dir
    test "errors when a user has reached their max total file size limit", %{
      tmp_dir: tmp_dir,
      user: user
    } do
      max_bytes = ContentRepo.user_upload_limits().max_bytes

      num_init_files = 4

      for _i <- 1..num_init_files do
        iodata = random_string(div(max_bytes, num_init_files))
        {:ok, mxc} = MatrixContentURI.new()
        %Upload{} = upload = Upload.new(mxc, "image/jpg", user, iodata)
        ContentRepo.save_upload(upload, iodata, tmp_dir)
      end

      iodata = random_string(div(max_bytes, num_init_files))
      {:ok, mxc} = MatrixContentURI.new()
      %Upload{} = upload = Upload.new(mxc, "image/jpg", user, iodata)
      assert {:error, {:quota_reached, :max_bytes}} = ContentRepo.save_upload(upload, iodata, tmp_dir)
    end

    @tag :tmp_dir
    test "errors when a user has reached their max file limit", %{
      tmp_dir: tmp_dir,
      iodata: iodata,
      user: user,
      upload: upload
    } do
      max_files = ContentRepo.user_upload_limits().max_files

      for _i <- 1..max_files do
        iodata = random_string(20)
        {:ok, mxc} = MatrixContentURI.new()
        %Upload{} = upload = Upload.new(mxc, "image/jpg", user, iodata)
        ContentRepo.save_upload(upload, iodata, tmp_dir)
      end

      assert {:error, {:quota_reached, :max_files}} = ContentRepo.save_upload(upload, iodata, tmp_dir)
    end

    @tag :tmp_dir
    test "errors when a disallowed mime type is given", %{tmp_dir: tmp_dir, iodata: iodata, user: user} do
      {:ok, mxc} = MatrixContentURI.new()
      %Upload{} = upload = Upload.new(mxc, "application/json", user, iodata)
      assert {:error, :invalid_mime_type} = ContentRepo.save_upload(upload, iodata, tmp_dir)
    end
  end
end
