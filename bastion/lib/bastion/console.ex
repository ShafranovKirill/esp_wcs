defmodule Bastion.Console do
  use Boundary,
    top_level?: true,
    deps: [Bastion.Events, Bastion.Fleet, Bastion.Link, Bastion.Access],
    exports: [Events.ConsoleTaken, Events.LockChanged]

  alias Bastion.Console.Application.Locks
  alias Bastion.Console.Domain.Line

  def child_spec(_opts), do: %{id: __MODULE__, start: {Locks, :start_link, [[]]}}

  @spec subscribe(String.t()) :: :ok
  def subscribe(id), do: Bastion.Events.subscribe({:console_lock, id})

  @type actor :: Bastion.Access.Actor.t()

  @spec attach(actor(), String.t()) ::
          {:ok, binary()} | {:busy, DateTime.t()} | {:error, :forbidden | :not_found}
  def attach(actor, id) do
    with :ok <- Bastion.Fleet.authorize(actor, "console.write", id),
         do: Locks.attach(id, actor)
  end

  @spec take(actor(), String.t()) :: {:ok, binary()} | {:error, :forbidden | :not_found}
  def take(actor, id) do
    with :ok <- Bastion.Fleet.authorize(actor, "console.write", id),
         do: Locks.take(id, actor)
  end

  @spec release(actor() | nil, String.t()) :: :ok
  def release(actor \\ nil, id), do: Locks.release(id, actor)

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

  @spec send_break(actor(), String.t(), pid()) :: :ok | {:error, term()}
  def send_break(actor, id, owner \\ self()) do
    with :ok <- Bastion.Fleet.authorize(actor, "console.write", id) do
      if Locks.owner?(id, owner) do
        with :ok <- Bastion.Link.command(id, "console_break", %{ms: Line.break_ms()}) do
          Bastion.Fleet.record_event(id, :command, %{op: "console_break"}, actor)
        end
      else
        {:error, :not_owner}
      end
    end
  end

  @spec configure(actor(), String.t(), map()) :: :ok | {:error, term()}
  def configure(actor, id, params) do
    with :ok <- Bastion.Fleet.authorize(actor, "device.configure", id),
         {:ok, line} <- Line.new(params),
         :ok <- Bastion.Link.command(id, "console_config", Line.to_args(line)) do
      Bastion.Fleet.record_event(
        id,
        :command,
        %{op: "console_config", line: Line.format(line)},
        actor
      )
    end
  end

  defdelegate bauds(), to: Line
  defdelegate format_line(line), to: Line, as: :format
end
