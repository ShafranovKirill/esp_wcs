defmodule Bastion.Discovery.Infrastructure.Responder do
  use GenServer
  require Logger

  alias Bastion.Discovery.Domain.Dns

  @mdns_group {224, 0, 0, 251}
  @mdns_port 5353

  @type reply :: :ignore | {:multicast, binary()} | {:unicast, binary()}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec answer(binary(), [:inet.ip4_address()], String.t(), :inet.port_number()) :: reply()
  def answer(packet, addresses, host \\ Bastion.Discovery.name(), src_port \\ @mdns_port) do
    with {:ok, query} <- Dns.parse_query(packet),
         [_ | _] <- addresses,
         [question | _] <- Enum.filter(query.questions, &Dns.wants_a?(&1, host)) do
      if src_port != @mdns_port,
        do: {:unicast, Dns.response(host, addresses, id: query.id, question: question)},
        else: reply_mode(question, Dns.response(host, addresses))
    else
      _ -> :ignore
    end
  end

  defp reply_mode(%{unicast: true}, packet), do: {:unicast, packet}
  defp reply_mode(_question, packet), do: {:multicast, packet}

  @impl true
  def init(opts) do
    host = Keyword.fetch!(opts, :name)

    case :gen_udp.open(@mdns_port, [
           :binary,
           active: true,
           reuseaddr: true,
           ip: {0, 0, 0, 0},
           add_membership: {@mdns_group, {0, 0, 0, 0}},
           multicast_loop: true,
           multicast_ttl: 255
         ]) do
      {:ok, socket} ->
        Logger.info("mDNS: answering #{host} with the built-in responder")
        {:ok, %{socket: socket, host: host}}

      {:error, reason} ->
        Logger.warning(
          "mDNS: port 5353 unavailable (#{inspect(reason)}), #{host} is not announced"
        )

        :ignore
    end
  end

  @impl true
  def handle_info({:udp, socket, ip, port, packet}, %{socket: socket} = state) do
    case answer(packet, addresses(), state.host, port) do
      {:multicast, reply} -> :gen_udp.send(socket, @mdns_group, @mdns_port, reply)
      {:unicast, reply} -> :gen_udp.send(socket, ip, port, reply)
      :ignore -> :ok
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec addresses() :: [:inet.ip4_address()]
  def addresses do
    case :inet.getifaddrs() do
      {:ok, ifaces} ->
        for {name, opts} <- ifaces,
            not virtual?(to_string(name)),
            :up in Keyword.get(opts, :flags, []),
            :loopback not in Keyword.get(opts, :flags, []),
            :pointtopoint not in Keyword.get(opts, :flags, []),
            {:addr, {_, _, _, _} = addr} <- opts,
            uniq: true,
            do: addr

      _ ->
        []
    end
  end

  @virtual_prefixes ~w(docker br- veth virbr vnet podman cni flannel cali vxlan wg)
  @virtual_parts ~w(tun tap)

  defp virtual?(name),
    do: String.starts_with?(name, @virtual_prefixes) or String.contains?(name, @virtual_parts)
end
