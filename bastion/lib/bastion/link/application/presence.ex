defmodule Bastion.Link.Application.Presence do
  use GenServer
  require Logger

  alias Bastion.Link.Events.PresenceChanged

  @table __MODULE__

  @type info :: %{
          optional(:rtt) => integer() | nil,
          optional(:rssi) => integer() | nil,
          optional(:uptime) => integer() | nil,
          optional(:heap) => integer() | nil,
          optional(:ip) => String.t() | nil,
          optional(:fw) => String.t() | nil,
          optional(:connected_at) => DateTime.t(),
          optional(:last_hb) => DateTime.t()
        }

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec register(String.t(), info()) :: :ok
  def register(id, info), do: GenServer.call(__MODULE__, {:register, id, self(), info})

  @spec update(String.t(), info()) :: :ok
  def update(id, info) do
    case :ets.lookup(@table, id) do
      [{^id, pid, old}] when pid == self() ->
        :ets.insert(@table, {id, pid, Map.merge(old, info)})
        Bastion.Events.publish({:device, id}, %PresenceChanged{id: id, online: true})
        Bastion.Events.publish(:link, %PresenceChanged{id: id, online: true})

      _ ->
        :ok
    end

    :ok
  end

  @spec get(String.t()) :: info() | nil
  def get(id) do
    case :ets.lookup(@table, id) do
      [{^id, _pid, info}] -> info
      [] -> nil
    end
  end

  @spec all() :: %{String.t() => info()}
  def all, do: :ets.foldl(fn {id, _pid, info}, acc -> Map.put(acc, id, info) end, %{}, @table)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{monitors: %{}}}
  end

  @impl true
  def handle_call({:register, id, pid, info}, _from, state) do
    case :ets.lookup(@table, id) do
      [{^id, old, _}] when old != pid -> send(old, :replaced)
      _ -> :ok
    end

    ref = Process.monitor(pid)
    :ets.insert(@table, {id, pid, info})
    publish(id, true)
    {:reply, :ok, put_in(state.monitors[ref], {id, pid})}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    {{id, ^pid}, monitors} = Map.pop(state.monitors, ref)

    case :ets.lookup(@table, id) do
      [{^id, ^pid, _}] ->
        :ets.delete(@table, id)
        record_disconnect(id)
        publish(id, false)

      _ ->
        :ok
    end

    {:noreply, %{state | monitors: monitors}}
  end

  defp record_disconnect(id) do
    Task.start(fn ->
      try do
        Bastion.Fleet.record_event(id, :disconnected, %{})
      rescue
        error ->
          Logger.warning("link: journal write failed for #{id}: #{Exception.message(error)}")
      catch
        :exit, reason ->
          Logger.warning("link: journal write failed for #{id}: #{inspect(reason)}")
      end
    end)
  end

  defp publish(id, online) do
    event = %PresenceChanged{id: id, online: online}
    Bastion.Events.publish(:link, event)
    Bastion.Events.publish({:device, id}, event)
  end
end
