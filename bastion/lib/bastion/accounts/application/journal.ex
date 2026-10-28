defmodule Bastion.Accounts.Application.Journal do
  import Ecto.Query

  alias Bastion.Accounts.AccessEvent
  alias Bastion.Accounts.Infrastructure.{AccessEventRecord, UserRecord}
  alias Bastion.Repo

  @username_max 64

  @spec record(AccessEvent.type(), keyword()) :: :ok
  def record(type, opts) do
    Repo.insert!(%AccessEventRecord{
      type: type,
      user_id: opts[:user_id],
      actor_id: opts[:actor_id],
      username: opts[:username] && String.slice(opts[:username], 0, @username_max),
      remote_ip: opts[:remote_ip],
      data: Map.new(opts[:data] || %{})
    })

    :ok
  end

  @spec list(pos_integer()) :: [AccessEvent.t()]
  def list(limit) do
    Repo.all(
      from e in AccessEventRecord,
        left_join: a in UserRecord,
        on: a.id == e.actor_id,
        order_by: [desc: e.inserted_at],
        limit: ^limit,
        select: {e, a.username}
    )
    |> Enum.map(fn {event, actor} -> AccessEventRecord.to_domain(event, actor) end)
  end
end
