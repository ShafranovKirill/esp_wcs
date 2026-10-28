defmodule BastionWeb.DashboardLiveTest do
  use BastionWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bastion.FleetFixtures

  alias Bastion.Fleet

  setup :log_in_user

  test "пусто — приглашение подключить устройство", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~s(id="empty")
    assert html =~ Bastion.PKI.bastion_code()
  end

  test "заявка появляется сама и одобряется после сверки кода", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    device = pending_device(%{name: "core-sw-01"})
    assert render(view) =~ "request-#{device.id}"
    assert render(view) =~ device.device_code

    view |> element("#approve-#{device.id}") |> render_click()
    assert render(view) =~ "Убедитесь, что код ниже совпадает"
    view |> element("#approve-confirm") |> render_click()

    assert Fleet.get_device(device.id).status == :approved
    refute has_element?(view, "#request-#{device.id}")
    assert has_element?(view, "#device-none-#{device.id}")
  end

  test "папки: создать и увидеть устройство в папке", %{conn: conn} do
    device = approved_device(%{name: "edge-rt"})
    {:ok, folder} = Fleet.create_folder(system(), "Склад")
    {:ok, _} = Fleet.set_folders(system(), device.id, [folder.id])

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#folder-#{folder.id} #device-#{folder.id}-#{device.id}")

    view |> element("#folder-form") |> render_submit(%{folder: %{name: "склад"}})
    assert render(view) =~ "Это имя уже занято"
  end

  test "дерево: подпапка, перенос, устройство в двух папках, удаление только пустой", %{
    conn: conn
  } do
    device = approved_device(%{name: "core-sw"})
    {:ok, building} = Fleet.create_folder(system(), "Здание А")
    {:ok, core} = Fleet.create_folder(system(), "Ядро сети")
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#new-subfolder-#{building.id}") |> render_click()
    view |> element("#folder-form") |> render_submit(%{folder: %{name: "Этаж 3"}})
    floor = Enum.find(Fleet.list_folders(), &(&1.name == "Этаж 3"))
    assert floor.parent_id == building.id
    assert has_element?(view, "#folder-#{building.id} #folder-#{floor.id}")

    {:ok, _} = Fleet.set_folders(system(), device.id, [floor.id, core.id])
    assert has_element?(view, "#folder-#{floor.id} #device-#{floor.id}-#{device.id}")
    assert has_element?(view, "#folder-#{core.id} #device-#{core.id}-#{device.id}")
    assert has_element?(view, "#folder-#{building.id} > div > button .badge", "1")

    refute has_element?(view, "#delete-folder-#{building.id}")
    assert has_element?(view, "#delete-folder-#{core.id}") == false

    view |> element("#move-folder-#{floor.id}") |> render_click()
    view |> element("#move-form") |> render_submit(%{move: %{parent_id: core.id}})
    assert Enum.find(Fleet.list_folders(), &(&1.id == floor.id)).parent_id == core.id
    assert has_element?(view, "#delete-folder-#{building.id}")
  end

  test "поиск по имени и MAC", %{conn: conn} do
    a = approved_device(%{name: "alpha"})
    b = approved_device(%{name: "beta"})
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#search-form") |> render_change(%{q: "alp"})
    assert has_element?(view, "#device-none-#{a.id}")
    refute has_element?(view, "#device-none-#{b.id}")

    mac = Fleet.format_mac(b.device_id)
    view |> element("#search-form") |> render_change(%{q: mac})
    assert has_element?(view, "#device-none-#{b.id}")
  end

  test "переключение языка на английский и обратно", %{conn: conn} do
    conn = post(conn, ~p"/locale", %{locale: "en", return_to: "/"})
    assert redirected_to(conn) == "/"
    {:ok, _view, html} = live(recycle(conn), ~p"/")
    assert html =~ "Devices"
    assert html =~ ~s(lang="en")

    conn = post(recycle(conn), ~p"/locale", %{locale: "ru", return_to: "//evil.example"})
    assert redirected_to(conn) == "/"
    {:ok, _view, html} = live(recycle(conn), ~p"/")
    assert html =~ "Устройства"
  end
end
