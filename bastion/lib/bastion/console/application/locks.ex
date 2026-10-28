defmodule Bastion.Console.Application.Locks do
  use GenServer
  require Logger

  alias Bastion.Console.Events.{ConsoleTaken, LockChanged}

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec attach(String.t(), term()) :: {:ok, binary()} | {:busy, DateTime.t()}
  def attach(id, actor \\ nil) do
    case GenServer.call(__MODULE__, {:attach, id, self()}) do
      :ok -> {:ok, became_owner(id, :console_taken, actor)}
      :already -> {:ok, history(id)}
      {:busy, since} -> {:busy, since}
    end
  end

  @spec take(String.t(), term()) :: {:ok, binary()}
  def take(id, actor \\ nil) do
    case GenServer.call(__MODULE__, {:take, id, self()}) do
      :already -> {:ok, history(id)}
      :ok -> {:ok, became_owner(id, :console_taken, actor)}
    end
  end

  @spec release(String.t(), term()) :: :ok
  def release(id, actor \\ nil) do
    Bastion.Link.unsubscribe_console(id)

    if GenServer.call(__MODULE__, {:release, id, self()}) == :ok,
      do: Bastion.Fleet.record_event(id, :console_released, %{}, actor)

    :ok
  end

  @spec lost(String.t()) :: :ok
  def lost(id), do: Bastion.Link.unsubscribe_console(id)

  @spec owner?(String.t(), pid()) :: boolean()
  def owner?(id, pid), do: match?([{^id, ^pid, _, _}], :ets.lookup(@table, id))

  @spec lock(String.t()) :: :free | {:owned, pid(), DateTime.t()}
  def lock(id) do
    case :ets.lookup(@table, id) do
      [{^id, pid, since, _ref}] -> {:owned, pid, since}
      [] -> :free
    end
  end

  defp became_owner(id, event, actor) do
    Bastion.Link.subscribe_console(id)
    Bastion.Fleet.record_event(id, event, %{}, actor)
    history(id)
  end

  defp history(id) do
    case Bastion.Link.console_history(id) do
      {:ok, data} -> data
      {:error, _} -> <<>>
    end
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:attach, id, pid}, _from, state) do
    case :ets.lookup(@table, id) do
      [{^id, ^pid, _, _}] -> {:reply, :already, state}
      [{^id, _other, since, _}] -> {:reply, {:busy, since}, state}
      [] -> {:reply, own(id, pid), state}
    end
  end

  def handle_call({:take, id, pid}, _from, state) do
    case :ets.lookup(@table, id) do
      [{^id, ^pid, _, _}] ->
        {:reply, :already, state}

      [{^id, other, _, ref}] ->
        Process.demonitor(ref, [:flush])
        send(other, {:event, %ConsoleTaken{id: id}})
        {:reply, own(id, pid), state}

      [] ->
        {:reply, own(id, pid), state}
    end
  end

  def handle_call({:release, id, pid}, _from, state) do
    case :ets.lookup(@table, id) do
      [{^id, ^pid, _, ref}] ->
        Process.demonitor(ref, [:flush])
        free(id)
        {:reply, :ok, state}

      _ ->
        {:reply, :not_owner, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case :ets.match_object(@table, {:_, pid, :_, ref}) do
      [{id, ^pid, _, ^ref}] ->
        free(id)
        journal_released(id)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  defp own(id, pid) do
    ref = Process.monitor(pid)
    :ets.insert(@table, {id, pid, DateTime.utc_now(:second), ref})
    Bastion.Events.publish({:console_lock, id}, %LockChanged{id: id, owned: true})
    :ok
  end

  defp free(id) do
    :ets.delete(@table, id)
    Bastion.Events.publish({:console_lock, id}, %LockChanged{id: id, owned: false})
  end

  defp journal_released(id) do
    Task.start(fn ->
      try do
        Bastion.Fleet.record_event(id, :console_released, %{})
      rescue
        error ->
          Logger.warning("console: journal write failed for #{id}: #{Exception.message(error)}")
      catch
        :exit, reason ->
          Logger.warning("console: journal write failed for #{id}: #{inspect(reason)}")
      end
    end)
  end
end
