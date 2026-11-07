defmodule BastionWeb.CommandSequenceLiveTest do
  use BastionWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Bastion.FleetFixtures
  alias Bastion.{FakeDevice, Fleet}

  setup :log_in_user

  defp prepare(view, script, ending \\ "cr") do
    view
    |> element("#sequence-form")
    |> render_submit(%{sequence: %{script: script, delay_ms: "50", ending: ending}})
  end

  test "preview does not send; confirmed run sends lines in order and records metadata", %{
    conn: conn
  } do
    device = approved_device()
    fake = device |> FakeDevice.start() |> FakeDevice.stop_on_exit()
    FakeDevice.send_text(fake, %{t: "credit", bytes: 1000})
    {:ok, view, _} = live(conn, ~p"/devices/#{device.id}")
    prepare(view, "enable\r\npassword supersecret\r\n", "crlf")
    refute_receive {:fake_frame, ^fake, {:binary, _}}, 50
    assert has_element?(view, "#sequence-start")
    view |> element("#sequence-start") |> render_click()
    assert_receive {:fake_frame, ^fake, {:binary, <<2, "enable\r\n">>}}
    assert_receive {:fake_frame, ^fake, {:binary, <<2, "password supersecret\r\n">>}}, 1000
    assert has_element?(view, "#sequence-progress", "Все строки отправлены")
    refute has_element?(view, "#sequence-stop")
    events = Enum.filter(Fleet.list_events(device.id), &(&1.data["op"] == "command_sequence"))
    assert Enum.any?(events, &(&1.data["status"] == "completed" and &1.data["sent"] == 2))
    refute inspect(events) =~ "supersecret"
  end

  test "stop cancels pending lines while waiting for credit and rejects manual input", %{
    conn: conn
  } do
    device = approved_device()
    fake = device |> FakeDevice.start() |> FakeDevice.stop_on_exit()
    {:ok, view, _} = live(conn, ~p"/devices/#{device.id}")
    prepare(view, "reload\nconfirm")
    view |> element("#sequence-start") |> render_click()
    render_hook(view, "console-input", %{data: "manual\r"})
    refute_receive {:fake_frame, ^fake, {:binary, _}}, 50
    view |> element("#sequence-stop") |> render_click()
    FakeDevice.send_text(fake, %{t: "credit", bytes: 1000})
    refute_receive {:fake_frame, ^fake, {:binary, _}}, 150
    assert has_element?(view, "#sequence-progress", "Отправка остановлена")
  end

  test "taking the console stops the previous operator's sequence", %{conn: conn} do
    device = approved_device()
    fake = device |> FakeDevice.start() |> FakeDevice.stop_on_exit()
    {:ok, first, _} = live(conn, ~p"/devices/#{device.id}")
    prepare(first, "configure terminal")
    first |> element("#sequence-start") |> render_click()
    {:ok, second, _} = live(conn, ~p"/devices/#{device.id}")
    second |> element("#console-take") |> render_click()
    assert has_element?(first, "#sequence-progress", "Отправка остановлена")
    FakeDevice.send_text(fake, %{t: "credit", bytes: 1000})
    refute_receive {:fake_frame, ^fake, {:binary, _}}, 150
  end

  test "leaving the console stops the sequence", %{conn: conn} do
    device = approved_device()
    fake = device |> FakeDevice.start() |> FakeDevice.stop_on_exit()
    {:ok, view, _} = live(conn, ~p"/devices/#{device.id}")
    prepare(view, "show version")
    view |> element("#sequence-start") |> render_click()
    view |> element("#tab-info") |> render_click()
    FakeDevice.send_text(fake, %{t: "credit", bytes: 1000})
    refute_receive {:fake_frame, ^fake, {:binary, _}}, 150

    assert Enum.any?(
             Fleet.list_events(device.id),
             &(&1.data["op"] == "command_sequence" and &1.data["status"] == "stopped")
           )
  end

  test "configuration file can be uploaded and previewed", %{conn: conn} do
    device = approved_device()
    device |> FakeDevice.start() |> FakeDevice.stop_on_exit()
    {:ok, view, _} = live(conn, ~p"/devices/#{device.id}")

    file =
      file_input(view, "#sequence-form", :command_file, [
        %{name: "switch.cfg", content: "enable\nshow version\n", type: "text/plain"}
      ])

    render_upload(file, "switch.cfg")
    prepare(view, "")
    assert has_element?(view, "#sequence-progress li", "show version")
    assert has_element?(view, "#sequence-start")
  end

  test "editing a reviewed configuration requires a new review", %{conn: conn} do
    device = approved_device()
    device |> FakeDevice.start() |> FakeDevice.stop_on_exit()
    {:ok, view, _} = live(conn, ~p"/devices/#{device.id}")
    prepare(view, "show version")
    assert has_element?(view, "#sequence-start")

    view
    |> element("#sequence-form")
    |> render_change(%{sequence: %{script: "reload", delay_ms: "50", ending: "cr"}})

    refute has_element?(view, "#sequence-start")
  end

  test "devices without credit cannot start an automated transfer", %{conn: conn} do
    device = approved_device()
    fake = device |> FakeDevice.start(caps: ["console"]) |> FakeDevice.stop_on_exit()
    {:ok, view, _} = live(conn, ~p"/devices/#{device.id}")
    prepare(view, "reload")
    view |> element("#sequence-start") |> render_click()
    assert has_element?(view, "#sequence-error")
    refute has_element?(view, "#sequence-stop")
    refute_receive {:fake_frame, ^fake, {:binary, _}}, 50
  end

  test "offline users cannot forge a transfer start", %{conn: conn} do
    device = approved_device()
    {:ok, view, _} = live(conn, ~p"/devices/#{device.id}")
    refute has_element?(view, "#sequence-preview[disabled]")
    prepare(view, "reload")
    assert has_element?(view, "#sequence-start[disabled]")

    [id] =
      view
      |> element("#sequence-start")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("phx-value-id")

    render_hook(view, "sequence-start", %{id: id})
    refute Enum.any?(Fleet.list_events(device.id), &(&1.data["op"] == "command_sequence"))
  end
end
