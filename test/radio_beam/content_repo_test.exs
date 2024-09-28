defmodule RadioBeam.ContentRepoTest do
  use ExUnit.Case, async: true
  doctest RadioBeam.ContentRepo

  alias RadioBeam.ContentRepo
  alias RadioBeam.ContentRepo.MatrixContentURI
  alias RadioBeam.ContentRepo.Upload

  describe "get/2" do
    setup do
      user = Fixtures.user()
      mxc = MatrixContentURI.new!()
      content = "A,B,C\nval1,val2,val3"
      upload = Upload.new(mxc, "text/csv", user, content)
      {:ok, _} = ContentRepo.save_upload(upload, content)

      %{user: user, mxc: mxc, upload: upload, content: content}
    end

    test "returns its upload and file content", %{mxc: mxc, content: content} do
      assert {:ok, %Upload{id: ^mxc, mime_type: "text/csv"}, upload_path} = ContentRepo.get(mxc)
      assert ^content = File.read!(upload_path)
    end

    test "returns :not_yet_uploaded for a pending upload", %{user: user} do
      mxc = MatrixContentURI.new!()
      ContentRepo.reserve(mxc, user)
      assert {:error, :not_yet_uploaded} = ContentRepo.get(mxc)
    end

    test "returns :not_found when an upload doesn't exist under the MXC" do
      assert {:error, :not_found} = ContentRepo.get(MatrixContentURI.new!())
    end
  end

  describe "reserve/2" do
    setup do
      user = Fixtures.user()
      {:ok, mxc} = MatrixContentURI.new()
      %{user: user, mxc: mxc}
    end

    test "succeeds with an :ok tuple of a pending upload", %{user: %{id: user_id} = user, mxc: mxc} do
      assert {:ok, %Upload{id: ^mxc, sha256: :pending, uploaded_by_id: ^user_id}} = ContentRepo.reserve(mxc, user)
    end

    test "errors when the mxc has already been reserved", %{user: user, mxc: mxc} do
      {:ok, _} = ContentRepo.reserve(mxc, user)
      assert {:error, :already_reserved} = ContentRepo.reserve(mxc, user)
    end

    test "errors when max pending uploads quota is reached", %{user: user, mxc: mxc} do
      %{max_pending: max_pending} = ContentRepo.user_upload_limits()
      for _i <- 1..max_pending, do: ContentRepo.reserve(MatrixContentURI.new!(), user)
      assert {:error, {:quota_reached, :max_pending}} = ContentRepo.reserve(mxc, user)
    end
  end

  describe "save_upload/3" do
    setup do
      user = Fixtures.user()
      iodata = Fixtures.random_string(20)
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
        iodata = Fixtures.random_string(div(max_bytes, num_init_files))
        {:ok, mxc} = MatrixContentURI.new()
        %Upload{} = upload = Upload.new(mxc, "image/jpg", user, iodata)
        ContentRepo.save_upload(upload, iodata, tmp_dir)
      end

      iodata = Fixtures.random_string(div(max_bytes, num_init_files))
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
        iodata = Fixtures.random_string(20)
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

    @tag :tmp_dir
    test "errors when a file exceeds the max single file upload limit", %{tmp_dir: tmp_dir, user: user} do
      mxc = MatrixContentURI.new!()
      iodata = "A,B,C\nval1,val2,#{Fixtures.random_string(ContentRepo.max_upload_size_bytes())}"

      %Upload{} = upload = Upload.new(mxc, "text/csv", user, iodata)
      assert {:error, :too_large} = ContentRepo.save_upload(upload, iodata, tmp_dir)
    end
  end
end
