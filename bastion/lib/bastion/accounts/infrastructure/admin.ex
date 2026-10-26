defmodule Bastion.Accounts.Infrastructure.Admin do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "admins" do
    field :username, :string
    field :password_hash, :string, redact: true

    timestamps(type: :utc_datetime)
  end

  def changeset(admin, username, password_hash) do
    admin
    |> change(username: username, password_hash: password_hash)
    |> validate_required([:username, :password_hash])
    |> unique_constraint(:username, name: :admins_username_index)
  end
end
