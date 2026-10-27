defmodule Bastion.Repo.Migrations.CreateAdmins do
  use Ecto.Migration

  def change do
    create table(:admins, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :username, :string, null: false
      add :password_hash, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:admins, ["lower(username)"], name: :admins_username_index)

    create table(:admin_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :admin_id, references(:admins, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :last_seen_at, :utc_datetime, null: false
      add :remote_ip, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:admin_sessions, [:token_hash])
    create index(:admin_sessions, [:admin_id])
  end
end
