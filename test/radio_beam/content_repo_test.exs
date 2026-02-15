defmodule RadioBeam.ContentRepoTest do
  use ExUnit.Case, async: true
  doctest RadioBeam.ContentRepo

  alias RadioBeam.ContentRepo.Thumbnail
  alias Vix.Vips.Operation
  alias Vix.Vips.Image
  alias RadioBeam.ContentRepo
  alias RadioBeam.ContentRepo.MatrixContentURI

  describe "download_info_for/2" do
    @describetag :tmp_dir
    setup %{tmp_dir: tmp_dir} do
      account = Fixtures.create_account()
      {:ok, mxc, _created_at} = ContentRepo.create(account.user_id)

      content = "A,B,C\nval1,val2,val3"
      file_info = Fixtures.file_info(content)
      tmp_upload_path = Path.join([tmp_dir, "tmp_upload"])
      File.write!(tmp_upload_path, content)

      file_acceptor = fn -> {:ok, file_info, tmp_upload_path, nil} end
      {:ok, mxc, nil} = ContentRepo.try_upload(mxc, account.user_id, file_acceptor, tmp_dir)

      %{account: account, upload_id: mxc, content: content}
    end

    test "returns its upload and file content", %{upload_id: upload_id, content: content, tmp_dir: tmp_dir} do
      assert {:ok, "txt", "TestUpload", path} = ContentRepo.download_info_for(upload_id, repo_path: tmp_dir)
      assert ^content = File.read!(path)
    end

    test "returns :not_yet_uploaded for a reserved upload", %{account: account, tmp_dir: tmp_dir} do
      {:ok, upload_id, _created_at} = ContentRepo.create(account.user_id)
      assert {:error, :not_yet_uploaded} = ContentRepo.download_info_for(upload_id, repo_path: tmp_dir)
    end

    test "returns :not_found when an upload doesn't exist under the MXC", %{tmp_dir: tmp_dir} do
      assert {:error, :not_found} = ContentRepo.download_info_for(MatrixContentURI.new!(), repo_path: tmp_dir)
    end
  end

  describe "get_thumbnail/2,3" do
    @describetag :tmp_dir

    setup do
      %{account: Fixtures.create_account()}
    end

    @width 1000
    @height 1000
    test "successfully thumbnails an upload for all allowed specs", %{tmp_dir: repo_path, account: account} do
      {upload_id, _file_info} = Fixtures.jpg_upload(account.user_id, @width, @height, repo_path, repo_path)

      for {w, h, method} = spec <- Thumbnail.allowed_specs() do
        assert {:ok, "jpg", "cool_picture", thumbnail_path} =
                 ContentRepo.thumbnail_info_for(upload_id, spec, repo_path: repo_path)

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
      account: account
    } do
      {upload_id, _file_info} = Fixtures.jpg_upload(account.user_id, @width, @height, repo_path, repo_path)

      for {w, h, _method} = spec <- Thumbnail.allowed_specs(), @width < w or @height < h do
        assert {:ok, "jpg", "cool_picture", thumbnail_path} =
                 ContentRepo.thumbnail_info_for(upload_id, spec, repo_path: repo_path)

        assert File.exists?(thumbnail_path)
        {:ok, _type, _filename, upload_path} = ContentRepo.download_info_for(upload_id, repo_path: repo_path)
        assert File.read!(upload_path) == File.read!(thumbnail_path)
      end
    end
  end

  describe "create/1" do
    @describetag :tmp_dir
    setup do
      %{account: Fixtures.create_account()}
    end

    test "succeeds with an :ok tuple of a reserved upload", %{account: %{user_id: user_id}} do
      assert {:ok, %MatrixContentURI{}, %DateTime{}} = ContentRepo.create(user_id)
    end

    test "errors when max reserved uploads quota is reached", %{account: %{user_id: user_id}} do
      %{max_reserved: max_reserved} = ContentRepo.user_upload_limits()
      for _i <- 1..max_reserved, do: ContentRepo.create(user_id)
      assert {:error, {:quota_reached, :max_reserved}} = ContentRepo.create(user_id)
    end

    test "errors when max uploaded files quota is reached", %{tmp_dir: repo_path, account: account} do
      %{max_files: max_files} = ContentRepo.user_upload_limits()

      for _i <- 1..max_files do
        upload_small_txt_file(account.user_id, repo_path)
      end

      assert {:error, {:quota_reached, :max_files}} = ContentRepo.create(account.user_id)
    end

    test "reserved uploads count towards max_files quota", %{tmp_dir: repo_path, account: account} do
      %{max_reserved: max_reserved, max_files: max_files} = ContentRepo.user_upload_limits()
      num_to_reserve = max_reserved - 2
      for _i <- 1..num_to_reserve, do: ContentRepo.create(account.user_id)

      for _i <- 1..(max_files - num_to_reserve) do
        upload_small_txt_file(account.user_id, repo_path)
      end

      assert {:error, {:quota_reached, :max_files}} = ContentRepo.create(account.user_id)
    end
  end

  describe "try_upload/3,4" do
    @describetag :tmp_dir
    setup %{tmp_dir: tmp_dir} do
      account = Fixtures.create_account()
      {:ok, upload_id, _created_at} = ContentRepo.create(account.user_id)

      content = Fixtures.random_string(20)
      tmp_upload_path = Path.join([tmp_dir, "tmp_upload"])
      File.write!(tmp_upload_path, content)
      file_info = Fixtures.file_info(content)
      file_acceptor = fn -> {:ok, file_info, tmp_upload_path, nil} end

      %{upload_id: upload_id, file_acceptor: file_acceptor, iodata: content, account: account}
    end

    test "successfully saves a user's first upload", %{
      account: %{user_id: user_id},
      tmp_dir: tmp_dir,
      upload_id: upload_id,
      file_acceptor: file_acceptor,
      iodata: iodata
    } do
      assert {:ok, upload_id, nil} = ContentRepo.try_upload(upload_id, user_id, file_acceptor, tmp_dir)

      {:ok, type, filename, upload_path} = ContentRepo.download_info_for(upload_id, repo_path: tmp_dir)
      assert IO.iodata_to_binary(iodata) == File.read!(upload_path)

      assert {:ok, %{id: ^upload_id, file: %{type: ^type, filename: ^filename}}} =
               ContentRepo.Database.fetch_upload(upload_id)
    end

    test "errors when a user has reached their max total file size limit", %{
      account: %{user_id: user_id},
      tmp_dir: tmp_dir,
      upload_id: upload_id,
      file_acceptor: file_acceptor
    } do
      max_bytes = ContentRepo.user_upload_limits().max_bytes

      num_init_files = 4

      for _i <- 1..num_init_files do
        {:ok, upload_id, _} = ContentRepo.create(user_id)

        iodata = Fixtures.random_string(div(max_bytes, num_init_files))
        tmp_upload_path = Path.join([tmp_dir, "tmp_upload"])
        File.write!(tmp_upload_path, iodata)
        file_acceptor = fn -> {:ok, Fixtures.file_info(iodata), tmp_upload_path, nil} end

        {:ok, _, _} = ContentRepo.try_upload(upload_id, user_id, file_acceptor, tmp_dir)
      end

      assert {:error, {:quota_reached, :max_bytes}} = ContentRepo.try_upload(upload_id, user_id, file_acceptor, tmp_dir)
    end

    test "errors when a file exceeds the max single file upload limit", %{
      account: %{user_id: user_id},
      tmp_dir: tmp_dir
    } do
      content = "A,B,C\nval1,val2,#{Fixtures.random_string(ContentRepo.max_upload_size_bytes())}"
      tmp_upload_path = Path.join([tmp_dir, "tmp_upload"])
      File.write!(tmp_upload_path, content)
      file_info = Fixtures.file_info(content)
      file_acceptor = fn -> {:ok, file_info, tmp_upload_path, nil} end

      {:ok, upload_id, _} = ContentRepo.create(user_id)

      assert {:error, :too_large} = ContentRepo.try_upload(upload_id, user_id, file_acceptor, tmp_dir)
    end
  end

  defp upload_small_txt_file(user_id, repo_path) do
    content = Fixtures.random_string(12)
    tmp_upload_path = Path.join([repo_path, "#{Fixtures.random_string(12)}.jpg"])
    File.write!(tmp_upload_path, content)
    file_info = Fixtures.file_info(content)
    file_acceptor = fn -> {:ok, file_info, tmp_upload_path, nil} end
    {:ok, small_upload_id, _} = ContentRepo.create(user_id)
    {:ok, ^small_upload_id, nil} = ContentRepo.try_upload(small_upload_id, user_id, file_acceptor, repo_path)
  end
end
