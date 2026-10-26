defmodule Bastion.Accounts.Infrastructure.ThrottleStore do
  @moduledoc """
  Счётчики неверных попыток входа по IP (в памяти). После перезапуска бастиона
  счётчики обнуляются — это допустимо: перебор всё равно упирается в паузы.
  """
  use GenServer

  alias Bastion.Accounts.Domain.Throttle

  @table __MODULE__
  # Записи без ошибок дольше суток удаляются, чтобы таблица не росла
  @cleanup_interval :timer.hours(1)
  @forget_after_s 24 * 3600

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec wait_seconds(String.t()) :: non_neg_integer()
  def wait_seconds(key), do: Throttle.wait_seconds(get(key), now())

  @spec failure(String.t()) :: non_neg_integer()
  def failure(key), do: GenServer.call(__MODULE__, {:failure, key})

  @spec reset(String.t()) :: :ok
  def reset(key), do: GenServer.call(__MODULE__, {:reset, key})

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    Process.send_after(self(), :cleanup, @cleanup_interval)
    {:ok, nil}
  end

  @impl true
  def handle_call({:failure, key}, _from, state) do
    now = now()
    throttle = Throttle.failure(get(key), now)
    :ets.insert(@table, {key, throttle, now})
    {:reply, Throttle.wait_seconds(throttle, now), state}
  end

  def handle_call({:reset, key}, _from, state) do
    :ets.delete(@table, key)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cutoff = now() - @forget_after_s
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    Process.send_after(self(), :cleanup, @cleanup_interval)
    {:noreply, state}
  end

  defp get(key) do
    case :ets.lookup(@table, key) do
      [{^key, throttle, _}] -> throttle
      [] -> Throttle.new()
    end
  end

  defp now, do: System.monotonic_time(:second)
end
