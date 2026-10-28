defmodule Bastion.ConsoleTest do
  use Bastion.DataCase, async: false

  import Bastion.FleetFixtures

  alias Bastion.Console
  alias Bastion.Console.Events.{ConsoleTaken, LockChanged}
  alias Bastion.FakeDevice
  alias Bastion.Fleet
  alias Bastion.Link.Events.ConsoleOutput

  setup do
    device = approved_device()
    %{device: device, fake: device |> FakeDevice.start() |> FakeDevice.stop_on_exit()}
  end

  defp start_tab do
    test = self()

    spawn_link(fn -> tab_loop(test) end)
  end

  defp tab_loop(test) do
    receive do
      {:run, fun} ->
        send(test, {:tab_result, self(), fun.()})
        tab_loop(test)

      :exit ->
        :ok

      message ->
        send(test, {:tab_message, self(), message})
        tab_loop(test)
    end
  end

  defp in_tab(tab, fun) do
    send(tab, {:run, fun})

    receive do
      {:tab_result, ^tab, result} -> result
    end
  end

  test "первая вкладка владеет консолью, вторая — «занято», «Забрать» отнимает", %{device: device} do
    Console.subscribe(device.id)
    first = start_tab()
    second = start_tab()

    assert {:ok, ""} = in_tab(first, fn -> Console.attach(system(), device.id) end)
    assert_receive {:event, %LockChanged{owned: true}}

    assert {:busy, %DateTime{}} = in_tab(second, fn -> Console.attach(system(), device.id) end)
    assert {:ok, _} = in_tab(second, fn -> Console.take(system(), device.id) end)

    assert_receive {:tab_message, ^first, {:event, %ConsoleTaken{}}}
    assert {:owned, ^second, _} = Console.lock(device.id)
    assert in_tab(first, fn -> Console.input(device.id, "x") end) == {:error, :not_owner}
  end

  test "владелец получает вывод и историю, ввод уходит в устройство", %{
    device: device,
    fake: fake
  } do
    FakeDevice.send_binary(fake, <<1, "before">>)
    Process.sleep(20)
    {:ok, "before"} = Console.attach(system(), device.id)

    FakeDevice.send_binary(fake, <<1, "after">>)
    assert_receive {:event, %ConsoleOutput{data: "after"}}

    FakeDevice.send_text(fake, %{t: "credit", bytes: 100})
    :ok = Console.input(device.id, "en\r")
    assert_receive {:fake_frame, ^fake, {:binary, <<2, "en\r">>}}
  end

  test "закрытая вкладка освобождает консоль, журнал пишет захват и освобождение", %{
    device: device
  } do
    Console.subscribe(device.id)
    pid = start_tab()
    {:ok, _} = in_tab(pid, fn -> Console.attach(system(), device.id) end)
    assert_receive {:event, %LockChanged{owned: true}}

    send(pid, :exit)
    assert_receive {:event, %LockChanged{owned: false}}
    assert Console.lock(device.id) == :free

    Process.sleep(100)
    types = device.id |> Fleet.list_events() |> Enum.map(& &1.type)
    assert :console_taken in types
    assert :console_released in types
  end

  test "BREAK — только владельцу; параметры порта проверяются до отправки", %{
    device: device,
    fake: fake
  } do
    assert Console.send_break(system(), device.id) == {:error, :not_owner}
    assert Console.configure(system(), device.id, %{"baud" => "12345"}) == {:error, :invalid_line}

    {:ok, _} = Console.attach(system(), device.id)
    owner = self()
    task = Task.async(fn -> Console.send_break(system(), device.id, owner) end)
    assert_receive {:fake_frame, ^fake, {:text, frame}}
    assert %{"op" => "console_break", "args" => %{"ms" => 300}, "id" => id} = JSON.decode!(frame)
    FakeDevice.send_text(fake, %{t: "cmd_result", id: id, ok: true})
    assert Task.await(task) == :ok

    params = %{"baud" => "115200", "data_bits" => "8", "parity" => "even", "stop_bits" => "1"}
    task = Task.async(fn -> Console.configure(system(), device.id, params) end)
    assert_receive {:fake_frame, ^fake, {:text, frame}}

    assert %{
             "op" => "console_config",
             "args" => %{"baud" => 115_200, "parity" => "even"},
             "id" => id
           } = JSON.decode!(frame)

    FakeDevice.send_text(fake, %{t: "cmd_result", id: id, ok: true})
    assert Task.await(task) == :ok
  end
end
