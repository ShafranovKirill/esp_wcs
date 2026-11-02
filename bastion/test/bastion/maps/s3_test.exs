defmodule Bastion.MapsS3Test do
  use Bastion.DataCase, async: false
  alias Bastion.{Fleet, Maps}

  setup do
    previous = Application.get_env(:bastion, Maps)

    Application.put_env(:bastion, Maps,
      storage: "s3",
      s3: [
        endpoint: "https://s3.example.test",
        bucket: "private-maps",
        region: "us-east-1",
        access_key_id: "test-access",
        secret_access_key: "test-secret",
        request_options: [plug: {Req.Test, __MODULE__}]
      ]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bastion, Maps, previous),
        else: Application.delete_env(:bastion, Maps)
    end)

    {:ok, folder} = Fleet.create_folder(system(), "S3 test")
    path = Path.join(System.tmp_dir!(), "s3-test-#{folder.id}.png")

    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
      )

    File.write!(path, png)
    on_exit(fn -> File.rm(path) end)
    %{folder: folder, path: path, png: png}
  end

  test "signed PUT and GET keep images private and use the stored bucket", c do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      assert [signature] = Plug.Conn.get_req_header(conn, "authorization")
      assert signature =~ "AWS4-HMAC-SHA256"
      assert signature =~ "test-access/"
      send(parent, {:s3_request, conn.method, conn.request_path})

      case conn.method do
        "PUT" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert body == c.png
          assert Plug.Conn.get_req_header(conn, "content-type") == ["image/png"]
          Plug.Conn.send_resp(conn, 200, "")

        "GET" ->
          Plug.Conn.send_resp(conn, 200, c.png)
      end
    end)

    assert {:ok, _} = Maps.set_background(system(), c.folder.id, c.path)
    assert {:ok, {:s3, "private-maps", key}, "image/png"} = Maps.background(system(), c.folder.id)
    assert_receive {:s3_request, "PUT", upload_path}
    assert upload_path == "/private-maps/" <> key
    assert {:ok, {:data, data}, "image/png"} = Maps.read_background(system(), c.folder.id)
    assert data == c.png
    assert_receive {:s3_request, "GET", ^upload_path}
    refute match?({:ok, _, _}, Maps.read_background(%Bastion.Access.Actor{}, c.folder.id))
    refute_receive {:s3_request, _, _}
  end

  test "storage failures preserve the existing image and return actionable errors", c do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)
    assert {:ok, _} = Maps.set_background(system(), c.folder.id, c.path)
    assert {:ok, original, _} = Maps.background(system(), c.folder.id)
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "internal details") end)
    assert {:error, :storage_unavailable} = Maps.set_background(system(), c.folder.id, c.path)
    assert {:ok, ^original, _} = Maps.background(system(), c.folder.id)
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 403, "secret details") end)
    assert {:error, :storage_denied} = Maps.set_background(system(), c.folder.id, c.path)
  end

  test "setup creates a missing bucket and handles a preexisting bucket" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/private-maps"

      case conn.method do
        "HEAD" -> Plug.Conn.send_resp(conn, 404, "")
        "PUT" -> Plug.Conn.send_resp(conn, 200, "")
      end
    end)

    assert :ok = Maps.setup_storage()

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "HEAD"
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert :ok = Maps.setup_storage()
  end
end
