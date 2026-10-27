defmodule Bastion.Console do
  use Boundary,
    top_level?: true,
    deps: [Bastion.Events, Bastion.Fleet, Bastion.Link],
    exports: [Events.ConsoleTaken, Events.LockChanged]

  alias Bastion.Console.Application.Locks
  alias Bastion.Console.Domain.Line

  def child_spec(_opts), do: %{id: __MODULE__, start: {Locks, :start_link, [[]]}}

  @spec subscribe(String.t()) :: :ok
  def subscribe(id), do: Bastion.Events.subscribe({:console_lock, id})

  @spec attach(String.t()) :: {:ok, binary()} | {:busy, DateTime.t()}
  defdelegate attach(id), to: Locks

  @spec take(String.t()) :: {:ok, binary()}
  defdelegate take(id), to: Locks

  @spec release(String.t()) :: :ok
  defdelegate release(id), to: Locks

  @spec lost(String.t()) :: :ok
  defdelegate lost(id), to: Locks

  @spec lock(String.t()) :: :free | {:owned, pid(), DateTime.t()}
  defdelegate lock(id), to: Locks

  @spec input(String.t(), binary()) :: :ok | {:error, :not_owner | :offline}
  def input(id, data) do
    if Locks.owner?(id, self()),
      do: Bastion.Link.console_input(id, data),
      else: {:error, :not_owner}
  end

  @spec send_break(String.t(), pid()) :: :ok | {:error, term()}
  def send_break(id, owner \\ self()) do
    if Locks.owner?(id, owner) do
      with :ok <- Bastion.Link.command(id, "console_break", %{ms: Line.break_ms()}) do
        Bastion.Fleet.record_event(id, :command, %{op: "console_break"})
      end
    else
      {:error, :not_owner}
    end
  end

  @spec configure(String.t(), map()) :: :ok | {:error, term()}
  def configure(id, params) do
    with {:ok, line} <- Line.new(params),
         :ok <- Bastion.Link.command(id, "console_config", Line.to_args(line)) do
      Bastion.Fleet.record_event(id, :command, %{op: "console_config", line: Line.format(line)})
    end
  end

  defdelegate bauds(), to: Line
  defdelegate format_line(line), to: Line, as: :format
end
