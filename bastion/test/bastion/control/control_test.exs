defmodule Bastion.ControlTest do
  use Bastion.DataCase, async: false

  import Bastion.FleetFixtures

  alias Bastion.Control
  alias Bastion.FakeDevice
  alias Bastion.Fleet

  setup do
    device = approved_device()
    %{device: device, fake: device |> FakeDevice.start() |> FakeDevice.stop_on_exit()}
  end

  defp reply(fake, ok \\ true) do
    assert_receive {:fake_frame, ^fake, {:text, frame}}
    cmd = JSON.decode!(frame)
    FakeDevice.send_text(fake, %{t: "cmd_result", id: cmd["id"], ok: ok})
    cmd
  end

  test "перезагрузка: команда и запись в журнале", %{device: device, fake: fake} do
    task = Task.async(fn -> Control.reboot(device.id) end)
    assert %{"op" => "reboot"} = reply(fake)
    assert Task.await(task) == :ok
    assert Enum.any?(Fleet.list_events(device.id), &(&1.type == :command))
  end

  test "смена Wi-Fi: проверка, пароль не попадает в журнал", %{device: device, fake: fake} do
    assert Control.set_wifi(device.id, %{"ssid" => "", "password" => ""}) ==
             {:error, :invalid_ssid}

    assert Control.set_wifi(device.id, %{"ssid" => "lab", "password" => "short"}) ==
             {:error, :invalid_password}

    task =
      Task.async(fn ->
        Control.set_wifi(device.id, %{"ssid" => "lab", "password" => "secret123"})
      end)

    assert %{"op" => "wifi_config", "args" => %{"ssid" => "lab", "password" => "secret123"}} =
             reply(fake)

    assert Task.await(task) == :ok

    event = device.id |> Fleet.list_events() |> Enum.find(&(&1.type == :command))
    assert event.data == %{"op" => "wifi_config", "ssid" => "lab"}
  end

  test "открытая сеть — пустой пароль допустим; ошибка устройства возвращается", %{
    device: device,
    fake: fake
  } do
    task =
      Task.async(fn -> Control.set_wifi(device.id, %{"ssid" => "guest", "password" => ""}) end)

    reply(fake, false)
    assert Task.await(task) == {:error, "failed"}
  end

  test "офлайн — offline" do
    assert Control.reboot(approved_device().id) == {:error, :offline}
  end
end
