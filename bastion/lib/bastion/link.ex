defmodule Bastion.Link do
  use Boundary,
    top_level?: true,
    deps: [Bastion.Events, Bastion.PKI, Bastion.Fleet],
    exports: [Events.PresenceChanged, Events.ConsoleOutput]

  alias Bastion.Link.Application.Presence

  @default_port 7443
  @request_timeout :timer.seconds(12)

  def child_spec(_opts) do
    config = config()

    %{
      id: __MODULE__,
      start:
        {Bastion.Link.Infrastructure.Supervisor, :start_link,
         [[port: port(), listen: Keyword.get(config, :listen, true)]]},
      type: :supervisor
    }
  end

  @spec port() :: :inet.port_number()
  def port, do: Keyword.get(config(), :port, @default_port)

  def subscribe, do: Bastion.Events.subscribe(:link)

  @spec presence(String.t()) :: Presence.info() | nil
  defdelegate presence(id), to: Presence, as: :get

  @spec online() :: %{String.t() => Presence.info()}
  defdelegate online(), to: Presence, as: :all

  @spec subscribe_console(String.t()) :: :ok
  def subscribe_console(id), do: Bastion.Events.subscribe({:console, id})

  @spec unsubscribe_console(String.t()) :: :ok
  def unsubscribe_console(id), do: Bastion.Events.unsubscribe({:console, id})

  @spec console_input(String.t(), binary()) :: :ok | {:error, :offline}
  def console_input(id, data) when is_binary(data) do
    case Presence.pid(id) do
      nil ->
        {:error, :offline}

      pid ->
        send(pid, {:console_input, data})
        :ok
    end
  end

  @spec console_history(String.t()) :: {:ok, binary()} | {:error, :offline | :timeout}
  def console_history(id), do: request(id, &{:console_history, &1, &2})

  @spec command(String.t(), String.t(), map()) ::
          :ok | {:error, :offline | :timeout | :rate_limited | String.t()}
  def command(id, op, args \\ %{}) when is_binary(op) and is_map(args),
    do: request(id, &{:command, &1, &2, op, args})

  defp request(id, message) do
    case Presence.pid(id) do
      nil ->
        {:error, :offline}

      pid ->
        ref = Process.monitor(pid)
        send(pid, message.(self(), ref))

        receive do
          {^ref, reply} ->
            Process.demonitor(ref, [:flush])
            reply

          {:DOWN, ^ref, :process, _pid, _reason} ->
            {:error, :offline}
        after
          @request_timeout ->
            Process.demonitor(ref, [:flush])
            {:error, :timeout}
        end
    end
  end

  defp config, do: Application.get_env(:bastion, __MODULE__, [])
end
