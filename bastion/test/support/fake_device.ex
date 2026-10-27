defmodule Bastion.FakeDevice do
  use Boundary, top_level?: true, check: [in: false, out: false]

  alias Bastion.Link.Application.Session

  def start(device, opts \\ []) do
    test = self()
    caps = Keyword.get(opts, :caps, ["console", "credit"])

    der = device.certificate_pem |> X509.Certificate.from_pem!() |> X509.Certificate.to_der()

    pid =
      spawn_link(fn ->
        {:ok, state} = Session.init(%{ip: "192.168.1.37", cert_der: der})

        hello =
          JSON.encode!(%{t: "hello", v: 1, device_id: device.device_id, fw: "1.0", caps: caps})

        state = deliver(test, Session.handle_in({hello, opcode: :text}, state))
        loop(test, state)
      end)

    assert_frame(pid, %{"t" => "welcome"})
    pid
  end

  def send_text(pid, json), do: send(pid, {:fake_in, {JSON.encode!(json), opcode: :text}})

  def send_binary(pid, data), do: send(pid, {:fake_in, {data, opcode: :binary}})

  def stop(pid) do
    ref = Process.monitor(pid)
    Process.unlink(pid)
    send(pid, :fake_stop)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    end
  end

  def stop_on_exit(pid) do
    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid), do: stop(pid)
      Process.sleep(50)
    end)

    pid
  end

  defp assert_frame(pid, pattern) do
    receive do
      {:fake_frame, ^pid, {:text, frame}} ->
        json = JSON.decode!(frame)
        true = Enum.all?(pattern, fn {k, v} -> json[k] == v end)
        json
    after
      1000 -> raise "no frame from fake device"
    end
  end

  defp loop(test, state) do
    receive do
      :fake_stop ->
        Session.terminate(:normal, state)
        exit(:normal)

      {:fake_in, frame} ->
        loop(test, deliver(test, Session.handle_in(frame, state)))

      message ->
        loop(test, deliver(test, Session.handle_info(message, state)))
    end
  end

  defp deliver(_test, {:ok, state}), do: state

  defp deliver(test, {:push, frames, state}) do
    for frame <- List.wrap(frames), do: send(test, {:fake_frame, self(), frame})
    state
  end

  defp deliver(test, {:stop, _reason, close, state}) do
    send(test, {:fake_closed, self(), close})
    Session.terminate(:normal, state)
    exit(:normal)
  end
end
