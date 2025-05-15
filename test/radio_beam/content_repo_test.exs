defmodule RadioBeam.ContentRepoTest do
  use ExUnit.Case, async: true
  doctest RadioBeam.ContentRepo

  alias RadioBeam.Repo
  alias RadioBeam.ContentRepo.Thumbnail
  alias Vix.Vips.Operation
  alias Vix.Vips.Image
  alias RadioBeam.ContentRepo.Upload.FileInfo
  alias RadioBeam.ContentRepo
  alias RadioBeam.ContentRepo.MatrixContentURI
  alias RadioBeam.ContentRepo.Upload

  describe "get/2" do
    @describetag :tmp_dir
    setup %{tmp_dir: tmp_dir} do
      user = Fixtures.user()
      {:ok, upload} = ContentRepo.create(user)
      content = "A,B,C\nval1,val2,val3"
      file_info = Fixtures.file_info(content)
      tmp_upload_path = Path.join([tmp_dir, "tmp_upload"])
      File.write!(tmp_upload_path, content)
      {:ok, upload} = ContentRepo.upload(upload, file_info, tmp_upload_path, tmp_dir)

      %{user: user, upload_id: upload.id, content: content}
    end

    test "returns its upload and file content", %{upload_id: upload_id, content: content, tmp_dir: tmp_dir} do
      assert {:ok, %Upload{id: ^upload_id, file: %FileInfo{type: "txt"}} = upload} =
               ContentRepo.get(upload_id, repo_path: tmp_dir)

      assert ^content = upload |> ContentRepo.upload_file_path(tmp_dir) |> File.read!()
    end

    test "returns :not_yet_uploaded for a reserved upload", %{user: user, tmp_dir: tmp_dir} do
      {:ok, %Upload{id: upload_id}} = ContentRepo.create(user)
      assert {:error, :not_yet_uploaded} = ContentRepo.get(upload_id, repo_path: tmp_dir)
    end

    test "returns :not_found when an upload doesn't exist under the MXC", %{tmp_dir: tmp_dir} do
      assert {:error, :not_found} = ContentRepo.get(MatrixContentURI.new!(), repo_path: tmp_dir)
    end
  end

  describe "get_thumbnail/2,3" do
    @describetag :tmp_dir

    setup do
      %{user: Fixtures.user()}
    end

    @width 1000
    @height 1000
    test "successfully thumbnails an upload for all allowed specs", %{tmp_dir: repo_path, user: user} do
      upload = Fixtures.jpg_upload(user, @width, @height, repo_path, repo_path)

      for {w, h, method} = spec <- Thumbnail.allowed_specs() do
        assert {:ok, thumbnail_path} = ContentRepo.get_thumbnail(upload, spec, repo_path: repo_path)
        assert File.exists?(thumbnail_path)

        {image, _} = Operation.jpegload!(thumbnail_path)

        case method do
          :scale ->
            # > “scale” tries to return an image where either the width or the height is
            # > smaller than the requested size."
            assert (Image.width(image) <= w and Image.height(image) == h) or
                     (Image.width(image) == w and Image.height(image) <= h)

          :crop ->
            # > “crop” tries to return an image where the width and height are close to
            # > the requested size and the aspect matches the requested size
            assert ^w = Image.width(image)
            assert ^h = Image.height(image)
        end
      end
    end

    @width 500
    @height 500
    test "returns the original image when one or both dimensions are smaller than the og media dimensions", %{
      tmp_dir: repo_path,
      user: user
    } do
      upload = Fixtures.jpg_upload(user, @width, @height, repo_path, repo_path)

      for {w, h, _method} = spec <- Thumbnail.allowed_specs(), @width < w or @height < h do
        assert {:ok, thumbnail_path} = ContentRepo.get_thumbnail(upload, spec, repo_path: repo_path)
        assert File.exists?(thumbnail_path)
        assert File.read!(ContentRepo.upload_file_path(upload, repo_path)) == File.read!(thumbnail_path)
      end
    end
  end

  describe "reserve/2" do
    setup do
      %{user: Fixtures.user()}
    end

    test "succeeds with an :ok tuple of a reserved upload", %{user: %{id: user_id} = user} do
      assert {:ok, %Upload{file: :reserved, uploaded_by_id: ^user_id}} = ContentRepo.create(user)
    end

    test "errors when max reserved uploads quota is reached", %{user: user} do
      %{max_reserved: max_reserved} = ContentRepo.user_upload_limits()
      for _i <- 1..max_reserved, do: ContentRepo.create(user)
      assert {:error, {:quota_reached, :max_reserved}} = ContentRepo.create(user)
    end

    @file_info Fixtures.file_info(Fixtures.random_string(12))
    test "errors when max uploaded files quota is reached", %{user: user} do
      %{max_files: max_files} = ContentRepo.user_upload_limits()
      for _i <- 1..max_files, do: user |> Upload.new() |> Upload.put_file(@file_info) |> Upload.put()
      assert {:error, {:quota_reached, :max_files}} = ContentRepo.create(user)
    end

    test "reserved uploads count towards max_files quota", %{user: user} do
      %{max_reserved: max_reserved, max_files: max_files} = ContentRepo.user_upload_limits()
      num_to_reserve = max_reserved - 2
      for _i <- 1..num_to_reserve, do: ContentRepo.create(user)
      for _i <- 1..(max_files - num_to_reserve), do: user |> Upload.new() |> Upload.put_file(@file_info) |> Upload.put()
      assert {:error, {:quota_reached, :max_files}} = ContentRepo.create(user)
    end
  end

  describe "upload/3" do
    @describetag :tmp_dir
    setup %{tmp_dir: tmp_dir} do
      user = Fixtures.user()
      {:ok, %Upload{} = upload} = ContentRepo.create(user)

      content = Fixtures.random_string(20)
      tmp_upload_path = Path.join([tmp_dir, "tmp_upload"])
      File.write!(tmp_upload_path, content)
      file_info = Fixtures.file_info(content)

      %{upload: upload, file_info: file_info, tmp_upload_path: tmp_upload_path, iodata: content, user: user}
    end

    test "successfully saves a user's first upload", %{
      tmp_dir: tmp_dir,
      upload: upload,
      file_info: file_info,
      tmp_upload_path: tmp_upload_path,
      iodata: iodata
    } do
      assert {:ok, upload} = ContentRepo.upload(upload, file_info, tmp_upload_path, tmp_dir)
      assert IO.iodata_to_binary(iodata) == File.read!(ContentRepo.upload_file_path(upload, tmp_dir))
      assert {:ok, ^upload} = Repo.fetch(Upload, upload.id)
    end

    test "errors when a user has reached their max total file size limit", %{
      file_info: file_info,
      tmp_dir: tmp_dir,
      tmp_upload_path: tmp_upload_path,
      upload: upload,
      user: user
    } do
      max_bytes = ContentRepo.user_upload_limits().max_bytes

      num_init_files = 4

      for _i <- 1..num_init_files do
        iodata = Fixtures.random_string(div(max_bytes, num_init_files))
        {:ok, %Upload{} = upload} = ContentRepo.create(user)
        tmp_upload_path = Path.join([tmp_dir, "tmp_upload"])
        File.write!(tmp_upload_path, iodata)
        ContentRepo.upload(upload, Fixtures.file_info(iodata), tmp_upload_path, tmp_dir)
      end

      assert {:error, {:quota_reached, :max_bytes}} =
               ContentRepo.upload(upload, file_info, tmp_upload_path, tmp_dir)
    end

    test "errors when a file exceeds the max single file upload limit", %{
      tmp_dir: tmp_dir,
      tmp_upload_path: tmp_upload_path,
      user: user
    } do
      iodata = "A,B,C\nval1,val2,#{Fixtures.random_string(ContentRepo.max_upload_size_bytes())}"
      {:ok, %Upload{} = upload} = ContentRepo.create(user)

      assert {:error, :too_large} = ContentRepo.upload(upload, Fixtures.file_info(iodata), tmp_upload_path, tmp_dir)
    end
  end
end
