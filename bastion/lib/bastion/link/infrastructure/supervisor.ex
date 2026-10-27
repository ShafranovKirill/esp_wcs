defmodule Bastion.Link.Infrastructure.Supervisor do
  use Supervisor
  require Logger

  alias Bastion.Link.Application.Presence
  alias Bastion.Link.Infrastructure.Listener

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    listener =
      if Keyword.get(opts, :listen, true),
        do: [Listener.child_spec(port: Keyword.fetch!(opts, :port)), {Task, &watch_certificate/0}],
        else: []

    Supervisor.init([Presence | listener], strategy: :one_for_one)
  end

  defp watch_certificate do
    Bastion.Events.subscribe(:pki)

    receive do
      {:event, %Bastion.PKI.Events.ServerCertificateRenewed{}} ->
        Logger.info("server certificate renewed, restarting WCS Link listener")
        Supervisor.terminate_child(__MODULE__, Listener)
        Supervisor.restart_child(__MODULE__, Listener)
    end

    watch_certificate()
  end
end
