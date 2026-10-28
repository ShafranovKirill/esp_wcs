defmodule Bastion.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    rename table(:admins), to: table(:users)

    execute "ALTER INDEX admins_username_index RENAME TO users_username_index",
            "ALTER INDEX users_username_index RENAME TO admins_username_index"

    alter table(:users) do
      add :blocked_at, :utc_datetime
      add :password_changed_at, :utc_datetime
    end

    rename table(:admin_sessions), to: table(:user_sessions)
    rename table(:user_sessions), :admin_id, to: :user_id

    create table(:access_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :type, :string, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :actor_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :username, :string
      add :remote_ip, :string
      add :data, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:access_events, [:inserted_at])
    create index(:access_events, [:user_id])
  end
end
