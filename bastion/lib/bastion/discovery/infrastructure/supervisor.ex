defmodule Bastion.Discovery.Infrastructure.Supervisor do
  use Supervisor
  require Logger

  alias Bastion.Discovery.Infrastructure.{Publisher, Responder}

  @avahi_socket "/run/avahi-daemon/socket"

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @spec method() :: :avahi | :dns_sd | :builtin | :off
  def method, do: :persistent_term.get({__MODULE__, :method}, :off)

  @impl true
  def init(opts) do
    method = choose(Keyword.fetch!(opts, :mode))
    :persistent_term.put({__MODULE__, :method}, method)

    children =
      case method do
        :off -> []
        :builtin -> [{Responder, opts}]
        method -> [{Publisher, Keyword.put(opts, :method, method)}]
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp choose(:auto) do
    cond do
      System.find_executable("avahi-publish") && File.exists?(@avahi_socket) -> :avahi
      match?({:unix, :darwin}, :os.type()) && System.find_executable("dns-sd") -> :dns_sd
      true -> :builtin
    end
  end

  defp choose(:avahi),
    do: if(System.find_executable("avahi-publish"), do: :avahi, else: unavailable(:avahi))

  defp choose(:dns_sd),
    do: if(System.find_executable("dns-sd"), do: :dns_sd, else: unavailable(:dns_sd))

  defp choose(mode) when mode in [:builtin, :off], do: mode

  defp unavailable(method) do
    Logger.warning("mDNS: #{method} not found, using the built-in responder")
    :builtin
  end
end
