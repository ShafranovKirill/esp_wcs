defmodule Bastion.Repo.Migrations.CreateAccess do
  use Ecto.Migration

  @roles [
    {"superadmin", "Суперадмин", ["superadmin"]},
    {"viewer", "Наблюдатель", ["view", "console.read"]},
    {"operator", "Оператор", ["view", "console.read", "console.write"]},
    {"engineer", "Инженер",
     [
       "view",
       "console.read",
       "console.write",
       "device.configure",
       "device.wifi",
       "device.reboot",
       "folder.manage"
     ]}
  ]

  def up do
    create table(:roles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :builtin, :string
      add :actions, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:roles, ["lower(name)"], name: :roles_name_index)
    create unique_index(:roles, [:builtin])

    create table(:groups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:groups, ["lower(name)"], name: :groups_name_index)

    create table(:group_members, primary_key: false) do
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true
    end

    create index(:group_members, [:user_id])

    create table(:grants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :role_id, references(:roles, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all)
      add :folder_id, references(:folders, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create constraint(:grants, :grantee_one, check: "(user_id IS NULL) <> (group_id IS NULL)")

    create unique_index(
             :grants,
             [
               :role_id,
               "COALESCE(user_id, '00000000-0000-0000-0000-000000000000'::uuid)",
               "COALESCE(group_id, '00000000-0000-0000-0000-000000000000'::uuid)",
               "COALESCE(folder_id, '00000000-0000-0000-0000-000000000000'::uuid)"
             ],
             name: :grants_unique_index
           )

    create index(:grants, [:user_id])
    create index(:grants, [:group_id])
    create index(:grants, [:folder_id])

    flush()

    for {key, name, actions} <- @roles do
      repo().query!(
        "INSERT INTO roles (id, name, builtin, actions, inserted_at, updated_at) VALUES (gen_random_uuid(), $1, $2, $3, now(), now())",
        [name, key, actions]
      )
    end

    execute """
    INSERT INTO grants (id, role_id, user_id, inserted_at)
    SELECT gen_random_uuid(), r.id, u.id, now()
    FROM users u, roles r WHERE r.builtin = 'superadmin'
    """
  end

  def down do
    drop table(:grants)
    drop table(:group_members)
    drop table(:groups)
    drop table(:roles)
  end
end
