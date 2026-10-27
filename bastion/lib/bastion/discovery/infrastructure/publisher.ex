defmodule Bastion.Discovery.Infrastructure.Publisher do
  use GenServer
  require Logger

  alias Bastion.Discovery.Infrastructure.Responder

  @refresh :timer.minutes(1)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    state = %{method: Keyword.fetch!(opts, :method), opts: opts, addresses: [], ports: []}
    {:ok, publish(state)}
  end

  @impl true
  def handle_info(:refresh, state), do: {:noreply, publish(state)}

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    Logger.warning("mDNS: #{state.method} exited with status #{status}, restarting")
    {:noreply, publish(%{state | addresses: []})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: close(state.ports)

  defp publish(state) do
    Process.send_after(self(), :refresh, @refresh)
    addresses = Responder.addresses()

    if addresses == state.addresses do
      state
    else
      close(state.ports)
      ports = Enum.map(addresses, &open(state.method, &1, state.opts))

      Logger.info(
        "mDNS: #{Keyword.fetch!(state.opts, :name)} via #{state.method} → #{format(addresses)}"
      )

      %{state | addresses: addresses, ports: ports}
    end
  end

  defp open(:avahi, ip, opts) do
    exe = System.find_executable("avahi-publish")
    spawn(exe, ["-a", "-R", Keyword.fetch!(opts, :name), :inet.ntoa(ip) |> to_string()])
  end

  defp open(:dns_sd, ip, opts) do
    exe = System.find_executable("dns-sd")
    ip = ip |> :inet.ntoa() |> to_string()
    port = opts |> Keyword.fetch!(:port) |> to_string()
    name = Keyword.fetch!(opts, :name)
    spawn(exe, ["-P", "ESP WCS Bastion #{ip}", "_https._tcp", "local", port, name, ip])
  end

  @guard ~S"""
  "$@" >/dev/null 2>&1 &
  child=$!
  trap 'kill $child 2>/dev/null' EXIT
  while read -r _; do :; done
  """

  defp spawn(exe, args) do
    Port.open({:spawn_executable, System.find_executable("sh")}, [
      :exit_status,
      :binary,
      args: ["-c", @guard, "mdns" | [exe | args]]
    ])
  end

  defp close(ports) do
    for port <- ports, Port.info(port) != nil, do: Port.close(port)
    :ok
  end

  defp format(addresses), do: Enum.map_join(addresses, ", ", &to_string(:inet.ntoa(&1)))
end
