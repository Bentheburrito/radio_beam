defmodule RadioBeamWeb.ContentRepoControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeam.ContentRepo.Thumbnail
  alias RadioBeam.ContentRepo.Upload
  alias RadioBeam.ContentRepo.MatrixContentURI
  alias RadioBeam.ContentRepo
  alias Vix.Vips.Operation
  alias Vix.Vips.Image

  describe "download/2" do
    @describetag :tmp_dir
    setup %{tmp_dir: tmp_dir} do
      user = Fixtures.user()
      {:ok, %Upload{} = upload} = ContentRepo.create(user)

      content = "A,B,C\nval1,val2,val2"
      tmp_upload_path = Path.join([tmp_dir, "tmp_upload"])
      File.write!(tmp_upload_path, content)
      ContentRepo.upload(upload, Fixtures.file_info(content, "csv", "a file to share"), tmp_upload_path)

      %{user: user, upload: upload, content: content}
    end

    test "returns an upload (200)", %{conn: conn, upload: %{id: mxc}, content: content} do
      conn = get(conn, ~p"/_matrix/client/v1/media/download/#{mxc.server_name}/#{mxc.id}", %{})
      assert ^content = response(conn, 200)
      assert ["text/csv"] = get_resp_header(conn, "content-type")

      assert [~s|inline; filename="a%20file%20to%20share"; filename*=utf-8''a%20file%20to%20share|] =
               get_resp_header(conn, "content-disposition")
    end

    test "returns an upload (200) but with a custom filename", %{conn: conn, upload: %{id: mxc}, content: content} do
      conn = get(conn, ~p"/_matrix/client/v1/media/download/#{mxc.server_name}/#{mxc.id}/funny_file", %{})
      assert ^content = response(conn, 200)
      assert ["text/csv"] = get_resp_header(conn, "content-type")
      assert [~s|inline; filename="funny_file"|] = get_resp_header(conn, "content-disposition")
    end

    test "returns M_NOT_FOUND (404) when no upload exists for the URI", %{conn: conn} do
      mxc = MatrixContentURI.new!()
      conn = get(conn, ~p"/_matrix/client/v1/media/download/#{mxc.server_name}/#{mxc.id}", %{})
      assert %{"errcode" => "M_NOT_FOUND"} = json_response(conn, 404)
    end

    test "returns M_BAD_PARAM (400) when the URI is malformed", %{conn: conn} do
      conn = get(conn, ~p"/_matrix/client/v1/media/download/UH+OH/abcd", %{})
      assert %{"errcode" => "M_BAD_PARAM"} = json_response(conn, 400)
    end

    test "returns M_NOT_YET_UPLOADED (504) when content is missing after waiting a bit", %{conn: conn, user: user} do
      {:ok, %{id: mxc}} = ContentRepo.create(user)
      conn = get(conn, ~p"/_matrix/client/v1/media/download/#{mxc.server_name}/#{mxc.id}?timeout_ms=200", %{})
      assert %{"errcode" => "M_NOT_YET_UPLOADED"} = json_response(conn, 504)
    end

    test "returns an upload (200), waiting a brief period for it to be uploaded", %{
      conn: conn,
      user: user,
      content: content,
      tmp_dir: tmp_dir
    } do
      {:ok, %{id: mxc} = upload} = ContentRepo.create(user)

      timeout = :timer.seconds(2)

      download_task =
        Task.async(fn ->
          get(conn, ~p"/_matrix/client/v1/media/download/#{mxc.server_name}/#{mxc.id}?timeout_ms=#{timeout}", %{})
        end)

      Process.sleep(div(timeout, 8))

      tmp_upload_path = Path.join([tmp_dir, "tmp_upload"])
      File.write!(tmp_upload_path, content)
      {:ok, _} = ContentRepo.upload(upload, Fixtures.file_info(content, "csv", "a file to share"), tmp_upload_path)

      conn = Task.await(download_task)

      assert ^content = response(conn, 200)
      assert ["text/csv"] = get_resp_header(conn, "content-type")

      assert [~s|inline; filename="a%20file%20to%20share"; filename*=utf-8''a%20file%20to%20share|] =
               get_resp_header(conn, "content-disposition")
    end

    test "returns M_TOO_LARGE (502) when content too large to serve", %{conn: conn, user: user, tmp_dir: tmp_dir} do
      max_upload_size = ContentRepo.max_upload_size_bytes()
      content = Fixtures.random_string(max_upload_size)
      {:ok, %{id: mxc} = upload} = ContentRepo.create(user)

      tmp_upload_path = Path.join([tmp_dir, "tmp_upload"])
      File.write!(tmp_upload_path, content)
      {:ok, upload} = ContentRepo.upload(upload, Fixtures.file_info(content, "csv"), tmp_upload_path)
      Upload.put(put_in(upload.file.byte_size, upload.file.byte_size + 1))

      conn = get(conn, ~p"/_matrix/client/v1/media/download/#{mxc.server_name}/#{mxc.id}?timeout_ms=200", %{})
      assert %{"errcode" => "M_TOO_LARGE"} = json_response(conn, 502)
    end
  end

  describe "thumbnail/2" do
    @describetag :tmp_dir
    @width 350
    @height 350
    setup %{tmp_dir: tmp_dir} do
      user = Fixtures.user()
      upload = Fixtures.jpg_upload(user, @width, @height, tmp_dir)

      %{user: user, upload: upload, dimensions: {@width, @height}}
    end

    @width 200
    @height 200
    @method "scale"
    test "returns a thumbnail (200) for an uploaded image", %{conn: conn, upload: %{id: mxc}} do
      params = %{"width" => @width, "height" => @height, "method" => @method}
      conn = get(conn, ~p"/_matrix/client/v1/media/thumbnail/#{mxc.server_name}/#{mxc.id}", params)

      assert image_content = response(conn, 200)
      assert ["image/jpeg"] = get_resp_header(conn, "content-type")

      {:ok, {expected_width, expected_height, _method}} =
        Thumbnail.coerce_spec(@width, @height, String.to_existing_atom(@method))

      assert {image, _flags} = Operation.jpegload_buffer!(image_content)
      assert Image.width(image) == min(expected_width, expected_height)
      assert Image.height(image) == min(expected_width, expected_height)
    end

    @width 250
    @height 250
    @method "scale"
    test "returns the original image (200) when the requested dimensions are larger than the image's", %{
      conn: conn,
      upload: %{id: mxc},
      dimensions: {expected_width, expected_height}
    } do
      params = %{"width" => @width, "height" => @height, "method" => @method}

      conn = get(conn, ~p"/_matrix/client/v1/media/thumbnail/#{mxc.server_name}/#{mxc.id}", params)

      assert image_content = response(conn, 200)
      assert ["image/jpeg"] = get_resp_header(conn, "content-type")

      assert {image, _flags} = Operation.jpegload_buffer!(image_content)
      assert Image.width(image) == expected_width
      assert Image.height(image) == expected_height
    end

    test "will disallow/not upscale for very large dimensions (400)", %{conn: conn, upload: %{id: mxc}} do
      params = %{"width" => 2 ** 32, "height" => 2 ** 32, "method" => "crop"}

      conn = get(conn, ~p"/_matrix/client/v1/media/thumbnail/#{mxc.server_name}/#{mxc.id}", params)

      assert %{"errcode" => "M_BAD_JSON", "error" => error} = json_response(conn, 400)
      assert error =~ "not supported"
    end

    test "will not thumbnail txt files (400)", %{conn: conn, tmp_dir: tmp_dir, user: user} do
      iodata = "this is not a picture !!!!!!"
      {:ok, %Upload{id: mxc} = upload} = ContentRepo.create(user)
      tmp_upload_path = Path.join([tmp_dir, "tmp_upload"])
      File.write!(tmp_upload_path, iodata)
      ContentRepo.upload(upload, Fixtures.file_info(iodata, "txt"), tmp_upload_path)
      params = %{"width" => @width, "height" => @height, "method" => @method}

      conn = get(conn, ~p"/_matrix/client/v1/media/thumbnail/#{mxc.server_name}/#{mxc.id}", params)

      assert %{"errcode" => "M_UNKNOWN", "error" => error} = json_response(conn, 400)
      assert error =~ "does not support thumbnailing txt files"
    end

    test "returns M_NOT_FOUND (404) if no upload exists for the given mxc", %{conn: conn} do
      params = %{"width" => @width, "height" => @height, "method" => @method}

      conn = get(conn, ~p"/_matrix/client/v1/media/thumbnail/localhost/whatareyoudoing", params)

      assert %{"errcode" => "M_NOT_FOUND"} = json_response(conn, 404)
    end

    test "returns M_NOT_YET_UPLOADED (504) if the upload has only been reserved (no content yet)", %{
      conn: conn,
      user: user
    } do
      {:ok, %{id: mxc}} = ContentRepo.create(user)
      params = %{"width" => @width, "height" => @height, "method" => @method, "timeout_ms" => 5}

      conn = get(conn, ~p"/_matrix/client/v1/media/thumbnail/#{mxc.server_name}/#{mxc.id}", params)

      assert %{"errcode" => "M_NOT_YET_UPLOADED"} = json_response(conn, 504)
    end

    test "returns M_TOO_LARGE (502) if the (local) content is too large", %{
      conn: conn,
      upload: %Upload{id: mxc} = upload
    } do
      Upload.put(put_in(upload.file.byte_size, upload.file.byte_size ** 2))

      params = %{"width" => @width, "height" => @height, "method" => @method}

      conn = get(conn, ~p"/_matrix/client/v1/media/thumbnail/#{mxc.server_name}/#{mxc.id}", params)

      assert %{"errcode" => "M_TOO_LARGE"} = json_response(conn, 502)
    end
  end

  describe "config/2" do
    test "returns an object (200) with the m.upload.size key", %{conn: conn} do
      conn = get(conn, ~p"/_matrix/client/v1/media/config", %{})
      assert %{"m.upload.size" => _} = json_response(conn, 200)
    end
  end

  describe "upload/2 (POST, no reservation)" do
    @describetag :tmp_dir
    test "accepts (200) an appropriately sized upload of an accepted type", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "text/csv")
        |> post(~p"/_matrix/media/v3/upload", "A,B,C\nval1,val2,val3")

      server_name = RadioBeam.server_name()
      assert %{"content_uri" => "mxc://" <> ^server_name <> "/" <> _} = json_response(conn, 200)
    end

    test "accepts (200) an appropriately sized upload with a default content type", %{conn: conn} do
      conn = post(conn, ~p"/_matrix/media/v3/upload", nil)
      server_name = RadioBeam.server_name()
      assert %{"content_uri" => "mxc://" <> ^server_name <> "/" <> _} = json_response(conn, 200)
    end

    test "rejects (401) an upload if an access token is not provided", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> put_req_header("content-type", "text/csv")
        |> post(~p"/_matrix/media/v3/upload", "A,B,C\nval1,val2,val3")

      assert %{"errcode" => "M_MISSING_TOKEN"} = json_response(conn, 401)
    end

    test "rejects (403) an upload of a disallowed mime type", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "random/csv")
        |> post(~p"/_matrix/media/v3/upload", "A,B,C\nval1,val2,val3")

      assert %{"errcode" => "M_FORBIDDEN"} = json_response(conn, 403)
    end

    test "rejects (413) an upload that is too large", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "text/csv")
        |> post(
          ~p"/_matrix/media/v3/upload",
          "A,B,C\nval1,val2,#{Fixtures.random_string(ContentRepo.max_upload_size_bytes())}"
        )

      assert %{"errcode" => "M_TOO_LARGE", "error" => error} = json_response(conn, 413)
      assert error =~ "Cannot upload files larger than"
    end

    test "rejects (403) an upload when a user has reached a quota", %{conn: conn, user: user, tmp_dir: tmp_dir} do
      max_bytes = ContentRepo.user_upload_limits().max_bytes
      max_upload_bytes = ContentRepo.max_upload_size_bytes()
      num_to_upload = div(max_bytes, max_upload_bytes)

      iodata = Fixtures.random_string(max_upload_bytes)

      for _i <- 1..num_to_upload do
        {:ok, %Upload{} = upload} = ContentRepo.create(user)
        tmp_upload_path = Path.join([tmp_dir, "tmp_upload"])
        File.write!(tmp_upload_path, iodata)
        ContentRepo.upload(upload, Fixtures.file_info(iodata, "jpg"), tmp_upload_path)
      end

      conn =
        conn
        |> put_req_header("content-type", "text/csv")
        |> post(~p"/_matrix/media/v3/upload", Fixtures.random_string(max_upload_bytes))

      assert %{"errcode" => "M_FORBIDDEN", "error" => error} = json_response(conn, 403)
      assert error =~ "uploaded too many files"
    end
  end

  describe "upload/2 (PUT, MXC URI reserved previously)" do
    @describetag :tmp_dir
    setup %{user: user} do
      {:ok, upload} = ContentRepo.create(user)
      %{upload: upload}
    end

    test "accepts (200) an appropriately sized upload with a previously reserved MXC URI", %{
      conn: conn,
      upload: %{id: mxc}
    } do
      conn =
        conn
        |> put_req_header("content-type", "text/csv")
        |> put(~p"/_matrix/media/v3/upload/#{mxc.server_name}/#{mxc.id}", "A,B,C\nval1,val2,val3")

      mxc_str = to_string(mxc)
      assert %{"content_uri" => ^mxc_str} = json_response(conn, 200)
    end

    test "will not use a supplied mxc that was reserved by someone else", %{conn: conn} do
      user = Fixtures.user()
      {:ok, %{id: mxc}} = ContentRepo.create(user)

      conn = put(conn, ~p"/_matrix/media/v3/upload/#{mxc.server_name}/#{mxc.id}", nil)
      assert %{"errcode" => "M_FORBIDDEN", "error" => error} = json_response(conn, 403)
      assert error =~ "must reserve a content URI"
    end

    test "will not use a supplied mxc that was not reserved", %{conn: conn} do
      conn = put(conn, ~p"/_matrix/media/v3/upload/localhost/abcdef3452", nil)
      assert %{"errcode" => "M_FORBIDDEN", "error" => error} = json_response(conn, 403)
      assert error =~ "must reserve a content URI"
    end

    test "rejects (409) when an upload has already used the given MXC URI", %{
      conn: conn,
      upload: %{id: mxc} = upload,
      tmp_dir: tmp_dir
    } do
      content = "abcd"
      tmp_upload_path = Path.join([tmp_dir, "tmp_upload"])
      File.write!(tmp_upload_path, content)
      {:ok, _} = ContentRepo.upload(upload, Fixtures.file_info(content, "csv"), tmp_upload_path)

      conn = put(conn, ~p"/_matrix/media/v3/upload/#{mxc.server_name}/#{mxc.id}", nil)
      assert %{"errcode" => "M_CANNOT_OVERWRITE_MEDIA", "error" => error} = json_response(conn, 409)
      assert error =~ "file already exists under this URI"
    end

    test "rejects (400) improperly formatted MXCs", %{conn: conn} do
      conn = put(conn, ~p"/_matrix/media/v3/upload/localhost/wait+why-all%the*math_symbols", nil)
      assert %{"errcode" => "M_BAD_PARAM", "error" => "Invalid content URI"} = json_response(conn, 400)
    end
  end

  describe "create/2" do
    test "creates and reserves a new MXC (200)", %{conn: conn} do
      conn = post(conn, ~p"/_matrix/media/v1/create", %{})

      server_name = RadioBeam.server_name()
      assert %{"content_uri" => "mxc://" <> ^server_name <> "/" <> _} = json_response(conn, 200)
    end

    test "returns M_LIMIT_EXCEEDED (429) when the user has too many pending uploads", %{conn: conn, user: user} do
      %{max_reserved: max_reserved} = ContentRepo.user_upload_limits()
      for _i <- 1..max_reserved, do: ContentRepo.create(user)

      conn = post(conn, ~p"/_matrix/media/v1/create", %{})

      assert %{"errcode" => "M_LIMIT_EXCEEDED", "error" => error} = json_response(conn, 429)
      assert error =~ "too many pending uploads"
    end
  end
end
