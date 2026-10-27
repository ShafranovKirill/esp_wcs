defmodule BastionWeb.TLS do
  use GenServer
  require Logger

  alias Bastion.PKI.Events.ServerCertificateRenewed

  @endpoint BastionWeb.Endpoint
  @supervisor Bastion.Supervisor

  def endpoint_child_spec do
    %{id: @endpoint, start: {__MODULE__, :start_endpoint, []}, type: :supervisor}
  end

  def start_endpoint do
    config = Application.get_env(:bastion, @endpoint, [])

    case Keyword.fetch(config, :https) do
      {:ok, https} -> @endpoint.start_link(https: put_ssl_options(https))
      :error -> @endpoint.start_link()
    end
  end

  defp put_ssl_options(https) do
    island = Keyword.get(https, :thousand_island_options, [])
    transport = Keyword.get(island, :transport_options, []) ++ Bastion.PKI.server_ssl_options()

    Keyword.put(
      https,
      :thousand_island_options,
      Keyword.put(island, :transport_options, transport)
    )
  end

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Bastion.Events.subscribe(:pki)
    {:ok, nil}
  end

  @impl true
  def handle_info({:event, %ServerCertificateRenewed{reason: reason}}, state) do
    Logger.info("server certificate renewed (#{reason}), restarting HTTPS endpoint")

    with :ok <- Supervisor.terminate_child(@supervisor, @endpoint),
         {:ok, _} <- Supervisor.restart_child(@supervisor, @endpoint) do
      :ok
    else
      error -> Logger.error("HTTPS endpoint restart failed: #{inspect(error)}")
    end

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}
end
