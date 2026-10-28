defmodule Bastion.Accounts.Infrastructure.AccessEventRecord do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "access_events" do
    field :type, Ecto.Enum, values: Bastion.Accounts.AccessEvent.types()
    field :user_id, :binary_id
    field :actor_id, :binary_id
    field :username, :string
    field :remote_ip, :string
    field :data, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def to_domain(%__MODULE__{} = r, actor) do
    %Bastion.Accounts.AccessEvent{
      id: r.id,
      type: r.type,
      user_id: r.user_id,
      actor_id: r.actor_id,
      username: r.username,
      actor: actor,
      remote_ip: r.remote_ip,
      data: r.data,
      at: r.inserted_at
    }
  end
end
