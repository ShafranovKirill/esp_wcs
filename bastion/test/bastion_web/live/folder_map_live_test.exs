defmodule BastionWeb.FolderMapLiveTest do
  use BastionWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Bastion.FleetFixtures
  alias Bastion.{Access, Fleet, Maps}
  setup :log_in_user

  setup do
    {:ok, folder} = Fleet.create_folder(system(), "Campus")
    {:ok, child} = Fleet.create_folder(system(), "Building", folder.id)
    device = approved_device()
    {:ok, device} = Fleet.set_folders(system(), device.id, [folder.id])
    %{folder: folder, child: child, device: device}
  end

  test "map link, edit, place, reload and remove", %{conn: conn} = c do
    {:ok, dashboard, _} = live(conn, ~p"/")
    assert has_element?(dashboard, "#folder-map-#{c.folder.id}")
    {:ok, view, _} = live(conn, ~p"/folders/#{c.folder.id}/map")
    view |> element("#map-panel-toggle") |> render_click()
    assert has_element?(view, "#map-unplaced #unplaced-#{c.child.id}")
    assert has_element?(view, "#map-unplaced #unplaced-#{c.device.id}")
    view |> element("#map-edit") |> render_click()
    view |> element("#map-change-cover") |> render_click()
    assert has_element?(view, "#map-upload")
    render_hook(view, "place", %{kind: "device", id: c.device.id, x: 0.2, y: 0.8})
    refute has_element?(view, "#map-unplaced #unplaced-#{c.device.id}")
    assert has_element?(view, "#remove-placement-#{c.device.id}")
    {:ok, reloaded, _} = live(conn, ~p"/folders/#{c.folder.id}/map")
    refute has_element?(reloaded, "#map-unplaced #unplaced-#{c.device.id}")
    view |> element("#remove-placement-#{c.device.id}") |> render_click()
    assert has_element?(view, "#unplaced-#{c.device.id}")
  end

  test "unauthorized users cannot read map or background", %{conn: conn} = c do
    {employee_conn, _} = log_in_employee(conn, "map-unauthorized")

    assert {:error, {:live_redirect, %{to: "/"}}} =
             live(employee_conn, ~p"/folders/#{c.folder.id}/map")

    assert employee_conn |> get(~p"/folders/#{c.folder.id}/background") |> response(404)
  end

  test "viewer cannot forge map mutations, revocation closes the page", %{conn: conn} = c do
    {employee_conn, user} = log_in_employee(conn, "map-viewer")
    role = Enum.find(Access.list_roles(), &(&1.builtin == "viewer"))

    {:ok, grant} =
      Access.grant(system(), %{user_id: user.id, role_id: role.id, folder_id: c.folder.id})

    {:ok, view, _} = live(employee_conn, ~p"/folders/#{c.folder.id}/map")
    refute has_element?(view, "#map-edit")
    render_hook(view, "place", %{kind: "device", id: c.device.id, x: 0.5, y: 0.5})
    assert {:ok, map} = Maps.fetch(system(), c.folder.id)
    assert Enum.all?(map.items, &is_nil(&1.x))
    :ok = Access.revoke(system(), grant.id)
    assert_redirect(view, "/")
  end

  test "background upload is served only through authenticated controller", %{conn: conn} = c do
    {:ok, view, _} = live(conn, ~p"/folders/#{c.folder.id}/map")
    view |> element("#map-edit") |> render_click()
    view |> element("#map-change-cover") |> render_click()

    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
      )

    upload =
      file_input(view, "#map-upload", :background, [
        %{name: "plan.png", content: png, type: "image/png"}
      ])

    render_upload(upload, "plan.png")
    view |> element("#map-upload") |> render_submit()
    assert {:ok, path, _} = Maps.background(system(), c.folder.id)
    on_exit(fn -> File.rm_rf(Path.dirname(path)) end)
    response_conn = get(conn, ~p"/folders/#{c.folder.id}/background")
    assert response(response_conn, 200) == png
    assert get_resp_header(response_conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(response_conn, "x-content-type-options") == ["nosniff"]
    view |> element("#map-clear-background") |> render_click()
    assert {:error, :not_found} = Maps.background(system(), c.folder.id)
  end

  test "folder status follows its devices and maps synchronize between tabs", %{conn: conn} = c do
    {:ok, device} = Fleet.set_folders(system(), c.device.id, [c.child.id])
    {:ok, _} = Maps.place(system(), c.folder.id, "folder", c.child.id, 0.5, 0.5)
    {:ok, first, _} = live(conn, ~p"/folders/#{c.folder.id}/map")
    {:ok, second, _} = live(conn, ~p"/folders/#{c.folder.id}/map")
    assert has_element?(first, "#folder-map[data-items*='offline']")
    fake = Bastion.FakeDevice.start(device)
    assert has_element?(first, "#folder-map[data-items*='online']")
    {:ok, _} = Bastion.Console.attach(system(), device.id)
    assert has_element?(first, "#folder-map[data-items*='busy']")
    assert :ok = Bastion.Console.release(system(), device.id)
    assert has_element?(first, "#folder-map[data-items*='online']")
    render_hook(first, "remove", %{kind: "folder", id: c.child.id})
    second |> element("#map-panel-toggle") |> render_click()
    assert has_element?(second, "#unplaced-#{c.child.id}")
    Bastion.FakeDevice.stop(fake)
  end

  test "early save cannot crash a pending upload and becomes available at completion",
       %{conn: conn} = c do
    {:ok, view, _} = live(conn, ~p"/folders/#{c.folder.id}/map")
    view |> element("#map-edit") |> render_click()
    view |> element("#map-change-cover") |> render_click()
    assert has_element?(view, "#map-upload-save[disabled]")
    png = File.read!(Path.expand("../docs/tz-image1.png"))

    upload =
      file_input(view, "#map-upload", :background, [
        %{name: "plan.png", content: png, type: "image/png"}
      ])

    render_upload(upload, "plan.png", 10)
    assert has_element?(view, "#map-upload-save[disabled]")
    render_hook(view, "upload", %{})
    assert has_element?(view, "#map-upload-error")
    assert {:error, :not_found} = Maps.background(system(), c.folder.id)
    render_upload(upload, "plan.png", 90)
    refute has_element?(view, "#map-upload-save[disabled]")
    view |> element("#map-upload") |> render_submit()
    assert {:ok, path, _} = Maps.background(system(), c.folder.id)
    on_exit(fn -> File.rm_rf(Path.dirname(path)) end)
    refute has_element?(view, "#map-upload-error")
  end

  test "S3 failure keeps the selected file for retry without closing the page",
       %{conn: conn} = c do
    previous = Application.get_env(:bastion, Maps)

    Application.put_env(:bastion, Maps,
      storage: "s3",
      s3: [
        endpoint: "https://s3.example.test",
        bucket: "private-maps",
        region: "us-east-1",
        access_key_id: "test",
        secret_access_key: "test",
        request_options: [plug: {Req.Test, __MODULE__}]
      ]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bastion, Maps, previous),
        else: Application.delete_env(:bastion, Maps)
    end)

    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
    {:ok, view, _} = live(conn, ~p"/folders/#{c.folder.id}/map")
    view |> element("#map-edit") |> render_click()
    view |> element("#map-change-cover") |> render_click()
    png = File.read!(Path.expand("../docs/tz-image1.png"))

    upload =
      file_input(view, "#map-upload", :background, [
        %{name: "plan.png", content: png, type: "image/png"}
      ])

    render_upload(upload, "plan.png")
    view |> element("#map-upload") |> render_submit()
    assert has_element?(view, "#map-upload-error")
    refute has_element?(view, "#map-upload-save[disabled]")
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)
    view |> element("#map-upload") |> render_submit()
    refute has_element?(view, "#map-upload-error")
    assert {:ok, {:s3, "private-maps", _}, _} = Maps.background(system(), c.folder.id)
  end

  test "unassigned device button opens the picker and placement assigns membership",
       %{conn: conn} = c do
    device = approved_device()
    {:ok, view, _} = live(conn, ~p"/folders/#{c.folder.id}/map")
    view |> element("#map-unfiled-toggle") |> render_click()
    assert has_element?(view, "#unfiled-#{device.id}")
    render_hook(view, "place", %{kind: "unfiled", id: device.id, x: 0.4, y: 0.6})
    refute has_element?(view, "#unfiled-#{device.id}")
    assert Fleet.get_device(device.id).folder_ids == [c.folder.id]
    assert has_element?(view, "#remove-placement-#{device.id}")
  end

  test "map opens in a dedicated viewport with explicit cover editor and exit",
       %{conn: conn} = c do
    {:ok, view, _} = live(conn, ~p"/folders/#{c.folder.id}/map")
    assert has_element?(view, "#map-command-bar")
    assert has_element?(view, "#map-back")
    refute has_element?(view, "#map-upload")
    view |> element("#map-edit") |> render_click()
    assert has_element?(view, "#map-change-cover")
    refute has_element?(view, "#map-upload")
    view |> element("#map-change-cover") |> render_click()
    assert has_element?(view, "#map-upload")
    view |> element("#map-close") |> render_click()
    assert_redirect(view, "/")
  end
end
