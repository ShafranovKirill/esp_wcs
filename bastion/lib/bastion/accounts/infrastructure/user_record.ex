defmodule Bastion.Accounts.Infrastructure.UserRecord do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :username, :string
    field :password_hash, :string, redact: true
    field :blocked_at, :utc_datetime
    field :password_changed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(record, username, password_hash) do
    record
    |> change(username: username, password_hash: password_hash)
    |> validate_required([:username, :password_hash])
    |> unique_constraint(:username, name: :users_username_index)
  end

  def to_domain(%__MODULE__{} = r) do
    %Bastion.Accounts.User{
      id: r.id,
      username: r.username,
      blocked_at: r.blocked_at,
      password_changed_at: r.password_changed_at,
      inserted_at: r.inserted_at
    }
  end
end
