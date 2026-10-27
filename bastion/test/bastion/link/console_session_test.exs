defmodule Bastion.Link.ConsoleSessionTest do
  use Bastion.DataCase, async: false

  import Bastion.FleetFixtures

  alias Bastion.FakeDevice
  alias Bastion.Link
  alias Bastion.Link.Events.ConsoleOutput

  setup do
    device = approved_device()
    %{device: device, fake: device |> FakeDevice.start() |> FakeDevice.stop_on_exit()}
  end

  test "вывод консоли рассылается подписчикам и копится в истории", %{device: device, fake: fake} do
    Link.subscribe_console(device.id)
    FakeDevice.send_binary(fake, <<1, "Switch>">>)

    assert_receive {:event, %ConsoleOutput{data: "Switch>"}}
    assert {:ok, "Switch>"} = Link.console_history(device.id)
  end

  test "история ограничена 64 КиБ", %{device: device, fake: fake} do
    for _ <- 1..20, do: FakeDevice.send_binary(fake, <<1>> <> :binary.copy("x", 4000))
    FakeDevice.send_binary(fake, <<1, "end">>)
    {:ok, history} = Link.console_history(device.id)
    assert byte_size(history) == 64 * 1024
    assert String.ends_with?(history, "end")
  end

  test "ввод уходит только в пределах кредита", %{device: device, fake: fake} do
    :ok = Link.console_input(device.id, "show version\r")
    refute_receive {:fake_frame, ^fake, {:binary, _}}, 100

    FakeDevice.send_text(fake, %{t: "credit", bytes: 4})
    assert_receive {:fake_frame, ^fake, {:binary, <<2, "show">>}}
    refute_receive {:fake_frame, ^fake, {:binary, _}}, 100

    FakeDevice.send_text(fake, %{t: "credit", bytes: 100})
    assert_receive {:fake_frame, ^fake, {:binary, <<2, " version\r">>}}
  end

  test "без флага credit ввод режется по 256 байт" do
    device = approved_device()
    fake = device |> FakeDevice.start(caps: ["console"]) |> FakeDevice.stop_on_exit()
    :ok = Link.console_input(device.id, :binary.copy("a", 600))

    assert_receive {:fake_frame, ^fake, {:binary, <<2, a::binary>>}}
    assert_receive {:fake_frame, ^fake, {:binary, <<2, b::binary>>}}
    assert_receive {:fake_frame, ^fake, {:binary, <<2, c::binary>>}}
    assert {byte_size(a), byte_size(b), byte_size(c)} == {256, 256, 88}
  end

  test "команда: cmd → cmd_result", %{device: device, fake: fake} do
    task = Task.async(fn -> Link.command(device.id, "reboot") end)
    assert_receive {:fake_frame, ^fake, {:text, frame}}
    assert %{"t" => "cmd", "id" => id, "op" => "reboot"} = JSON.decode!(frame)

    FakeDevice.send_text(fake, %{t: "cmd_result", id: id, ok: false, error: "invalid_args"})
    assert Task.await(task) == {:error, "invalid_args"}
  end

  test "команда без ответа — timeout, обрыв — offline", %{device: device, fake: fake} do
    task = Task.async(fn -> Link.command(device.id, "reboot") end)
    assert_receive {:fake_frame, ^fake, {:text, frame}}
    %{"id" => id} = JSON.decode!(frame)
    send(fake, {:cmd_timeout, id})
    assert Task.await(task) == {:error, :timeout}

    task = Task.async(fn -> Link.command(device.id, "reboot") end)
    assert_receive {:fake_frame, ^fake, {:text, _}}
    FakeDevice.stop(fake)
    assert Task.await(task) == {:error, :offline}
    assert Link.command(device.id, "reboot") == {:error, :offline}
  end

  test "больше 10 команд в секунду — rate_limited", %{device: device, fake: fake} do
    tasks = for _ <- 1..11, do: Task.async(fn -> Link.command(device.id, "reboot") end)

    for _ <- 1..10 do
      assert_receive {:fake_frame, ^fake, {:text, frame}}
      FakeDevice.send_text(fake, %{t: "cmd_result", id: JSON.decode!(frame)["id"], ok: true})
    end

    results = tasks |> Enum.map(&Task.await/1) |> Enum.frequencies()
    assert results == %{:ok => 10, {:error, :rate_limited} => 1}
  end

  test "status обновляет параметры порта и IP", %{device: device, fake: fake} do
    FakeDevice.send_text(fake, %{
      t: "status",
      console: %{baud: 115_200, data_bits: 8, parity: "none", stop_bits: 1},
      ip: "10.0.0.5"
    })

    Process.sleep(50)

    assert %{console: %{baud: 115_200, parity: :none}, ip: "10.0.0.5"} =
             Link.presence(device.id)
  end

  test "неизвестный канал в бинарном кадре — 4000", %{fake: fake} do
    FakeDevice.send_binary(fake, <<2, "x">>)
    assert_receive {:fake_closed, ^fake, {4000, _}}
  end
end
