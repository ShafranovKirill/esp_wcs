defmodule BastionWeb.DeviceLiveTest do
  use BastionWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bastion.FleetFixtures

  alias Bastion.FakeDevice
  alias Bastion.Fleet

  setup :log_in_user

  describe "консоль" do
    test "владелец вводит команды, вторая вкладка видит «Устройство занято» и забирает консоль",
         %{conn: conn} do
      device = approved_device()
      fake = device |> FakeDevice.start() |> FakeDevice.stop_on_exit()
      FakeDevice.send_binary(fake, <<1, "Switch>">>)
      FakeDevice.send_text(fake, %{t: "credit", bytes: 1000})

      {:ok, first, _} = live(conn, ~p"/devices/#{device.id}")
      assert_push_event(first, "console-reset", %{data: history})
      assert Base.decode64!(history) == "Switch>"
      assert_push_event(first, "console-state", %{owner: true})
      refute has_element?(first, "#console-busy")

      render_hook(first, "console-input", %{"data" => "en\r"})
      assert_receive {:fake_frame, ^fake, {:binary, <<2, "en\r">>}}

      FakeDevice.send_binary(fake, <<1, "Switch#">>)
      assert_push_event(first, "console-output", %{data: data})
      assert Base.decode64!(data) == "Switch#"

      {:ok, second, _} = live(conn, ~p"/devices/#{device.id}")
      assert has_element?(second, "#console-busy")

      second |> element("#console-take") |> render_click()
      assert_push_event(second, "console-state", %{owner: true})
      assert render(first) =~ ~s(id="console-busy")
      refute has_element?(second, "#console-busy")
    end

    test "офлайн-устройство — предупреждение, неодобренное — консоль недоступна", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/devices/#{approved_device().id}")
      assert has_element?(view, "#console-offline")

      {:ok, view, _} = live(conn, ~p"/devices/#{pending_device().id}")
      assert has_element?(view, "#console-unavailable")
    end
  end

  test "вкладки: консоль нарисована, сведения, журнал", %{conn: conn} do
    device = approved_device(%{name: "core-sw-01"})

    {:ok, view, html} = live(conn, ~p"/devices/#{device.id}")
    assert html =~ ~s(phx-hook="Terminal")

    assert view |> element("#tab-info") |> render_click() =~ Fleet.format_mac(device.device_id)
    assert_patch(view, ~p"/devices/#{device.id}/info")

    html = view |> element("#tab-journal") |> render_click()
    assert html =~ "Одобрено, сертификат выдан"
  end

  test "заявка: баннер, одобрение со страницы устройства", %{conn: conn} do
    device = pending_device()
    {:ok, view, html} = live(conn, ~p"/devices/#{device.id}/info")
    assert html =~ ~s(id="request-banner")

    view |> element("#approve-confirm") |> render_click()
    refute has_element?(view, "#request-banner")
    assert Fleet.get_device(device.id).status == :approved
  end

  test "переименование и перенос в папку", %{conn: conn} do
    device = approved_device(%{name: "old"})
    approved_device(%{name: "taken"})
    {:ok, folder} = Fleet.create_folder("Склад")

    {:ok, view, _} = live(conn, ~p"/devices/#{device.id}/settings")

    assert view |> element("#rename-form") |> render_submit(%{device: %{name: "TAKEN"}}) =~
             "Это имя уже занято"

    view |> element("#rename-form") |> render_submit(%{device: %{name: "core-sw-01"}})
    assert has_element?(view, "#device-name", "core-sw-01")

    view
    |> element("#folder-form")
    |> render_change(%{device: %{folder_ids: ["", folder.id]}})

    assert Fleet.get_device(device.id).folder_ids == [folder.id]
    assert has_element?(view, "#folder-check-#{folder.id}[checked]")

    view |> element("#folder-form") |> render_change(%{device: %{folder_ids: [""]}})
    assert Fleet.get_device(device.id).folder_ids == []
  end

  test "настройки онлайн-устройства: порт, Wi-Fi, перезагрузка", %{conn: conn} do
    device = approved_device()
    fake = device |> FakeDevice.start() |> FakeDevice.stop_on_exit()
    {:ok, view, _} = live(conn, ~p"/devices/#{device.id}/settings")

    refute has_element?(view, "#reboot[disabled]")

    view
    |> element("#wifi-form")
    |> render_submit(%{wifi: %{ssid: "lab", password: "secret123"}})

    assert_receive {:fake_frame, ^fake, {:text, frame}}
    assert %{"op" => "wifi_config", "id" => id} = JSON.decode!(frame)
    FakeDevice.send_text(fake, %{t: "cmd_result", id: id, ok: true})
    assert render_async(view) =~ "сохранило новую сеть"

    view |> element("#reboot") |> render_click()
    assert_receive {:fake_frame, ^fake, {:text, frame}}
    assert %{"op" => "reboot", "id" => id} = JSON.decode!(frame)
    FakeDevice.send_text(fake, %{t: "cmd_result", id: id, ok: true})
    assert render_async(view) =~ "перезагружается"

    view
    |> element("#settings-line")
    |> render_change(%{line: %{baud: "115200", data_bits: "8", parity: "none", stop_bits: "1"}})

    assert_receive {:fake_frame, ^fake, {:text, frame}}
    assert %{"op" => "console_config", "args" => %{"baud" => 115_200}} = JSON.decode!(frame)
  end

  test "настройки офлайн-устройства недоступны", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/devices/#{approved_device().id}/settings")
    assert has_element?(view, "#reboot[disabled]")
    assert has_element?(view, "#wifi-submit[disabled]")
  end

  test "удалить можно только после отзыва", %{conn: conn} do
    device = approved_device()
    {:ok, view, _} = live(conn, ~p"/devices/#{device.id}/settings")

    assert has_element?(view, "#delete[disabled]")
    view |> element("#revoke") |> render_click()
    assert Fleet.get_device(device.id).status == :revoked

    view |> element("#delete") |> render_click()
    assert_redirect(view, ~p"/")
    assert Fleet.get_device(device.id) == nil
  end

  test "несуществующее устройство — на главную", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} =
             live(conn, ~p"/devices/#{Ecto.UUID.generate()}")
  end
end
