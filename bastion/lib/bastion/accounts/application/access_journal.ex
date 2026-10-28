defmodule Bastion.Accounts.Application.AccessJournal do
  use GenServer

  alias Bastion.Access.Events.GrantsChanged
  alias Bastion.Accounts.Application.Journal
  alias Bastion.Accounts.Infrastructure.UserRecord
  alias Bastion.Repo

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec sync() :: :ok
  def sync, do: GenServer.call(__MODULE__, :sync)

  @impl true
  def init(nil) do
    Bastion.Access.subscribe()
    {:ok, nil}
  end

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:event, %GrantsChanged{change: change} = event}, state)
      when not is_nil(change) do
    user = event.user_id && Repo.get(UserRecord, event.user_id)

    Journal.record(change,
      user_id: user && user.id,
      username: user && user.username,
      actor_id: event.actor_id,
      data: event.data
    )

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
