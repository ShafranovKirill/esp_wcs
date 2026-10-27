defmodule Bastion.PKI.Infrastructure.HostDiscovery do
  @virtual_prefixes ~w(lo docker br- veth virbr vmnet vboxnet tun tap wg zt utun awdl llw bridge)

  @spec hostname() :: String.t() | nil
  def hostname do
    case :inet.gethostname() do
      {:ok, name} -> name |> to_string() |> String.split(".") |> hd()
      _ -> nil
    end
  end

  @spec addresses() :: [:inet.ip_address()]
  def addresses do
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        for {name, opts} <- interfaces,
            not virtual?(to_string(name)),
            :up in Keyword.get(opts, :flags, []),
            {:addr, addr} <- opts,
            uniq: true,
            do: addr

      {:error, _} ->
        []
    end
  end

  defp virtual?(name), do: Enum.any?(@virtual_prefixes, &String.starts_with?(name, &1))
end
