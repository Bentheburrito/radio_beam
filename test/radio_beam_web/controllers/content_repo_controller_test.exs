defmodule RadioBeamWeb.ContentRepoControllerTest do
  use RadioBeamWeb.ConnCase, async: true

  alias RadioBeam.ContentRepo.Upload
  alias RadioBeam.ContentRepo.MatrixContentURI
  alias RadioBeam.ContentRepo

  setup %{conn: conn} do
    user1 = Fixtures.user()
    device = Fixtures.device(user1.id, "da steam deck")

    %{
      conn: put_req_header(conn, "authorization", "Bearer #{device.access_token}"),
      user: user1,
      device: device
    }
  end

  describe "config/2" do
    test "returns an object (200) with the m.upload.size key", %{conn: conn} do
      conn = get(conn, ~p"/_matrix/client/v1/media/config", %{})
      assert %{"m.upload.size" => _} = json_response(conn, 200)
    end
  end

  describe "upload/2" do
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
      # dispatch(nil, nil, nil, nil)
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
        |> put_req_header("content-type", "random/csv")
        |> post(
          ~p"/_matrix/media/v3/upload",
          "A,B,C\nval1,val2,#{Fixtures.random_string(ContentRepo.max_upload_size_bytes())}"
        )

      assert %{"errcode" => "M_FORBIDDEN", "error" => error} = json_response(conn, 413)
      assert error =~ "Cannot upload files larger than"
    end

    test "rejects (403) an upload when a user has reached a quota", %{conn: conn, user: user} do
      max_bytes = ContentRepo.user_upload_limits().max_bytes

      iodata = Fixtures.random_string(max_bytes - 1)
      {:ok, mxc} = MatrixContentURI.new()
      %Upload{} = upload = Upload.new(mxc, "image/jpg", user, iodata)
      ContentRepo.save_upload(upload, iodata)

      conn =
        conn
        |> put_req_header("content-type", "random/csv")
        |> post(~p"/_matrix/media/v3/upload", "A,B,C\nval1,val2,val3")

      assert %{"errcode" => "M_FORBIDDEN", "error" => error} = json_response(conn, 403)
      assert error =~ "uploaded too many files"
    end
  end
end
