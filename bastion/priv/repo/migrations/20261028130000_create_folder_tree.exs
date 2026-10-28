defmodule Bastion.Repo.Migrations.CreateFolderTree do
  use Ecto.Migration

  def up do
    alter table(:folders) do
      add :parent_id, references(:folders, type: :binary_id, on_delete: :restrict)
      add :path, :text
    end

    execute "UPDATE folders SET path = id::text"

    alter table(:folders) do
      modify :path, :text, null: false
    end

    drop index(:folders, ["lower(name)"], name: :folders_name_index)

    create unique_index(
             :folders,
             ["COALESCE(parent_id, '00000000-0000-0000-0000-000000000000'::uuid)", "lower(name)"],
             name: :folders_sibling_name_index
           )

    create unique_index(:folders, [:path])
    execute "CREATE INDEX folders_path_prefix_index ON folders (path text_pattern_ops)"
    create index(:folders, [:parent_id])

    create table(:device_folders, primary_key: false) do
      add :device_id, references(:devices, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :folder_id, references(:folders, type: :binary_id, on_delete: :restrict),
        primary_key: true
    end

    create index(:device_folders, [:folder_id])

    execute """
    INSERT INTO device_folders (device_id, folder_id)
    SELECT id, folder_id FROM devices WHERE folder_id IS NOT NULL
    """

    alter table(:devices) do
      remove :folder_id
    end
  end

  def down do
    alter table(:devices) do
      add :folder_id, references(:folders, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:devices, [:folder_id])

    execute """
    UPDATE devices d SET folder_id = (
      SELECT df.folder_id FROM device_folders df WHERE df.device_id = d.id LIMIT 1
    )
    """

    drop table(:device_folders)
    execute "DELETE FROM folders WHERE parent_id IS NOT NULL"
    execute "DROP INDEX folders_path_prefix_index"
    drop index(:folders, [:path])
    drop index(:folders, [:parent_id])
    drop index(:folders, [], name: :folders_sibling_name_index)
    create unique_index(:folders, ["lower(name)"], name: :folders_name_index)

    alter table(:folders) do
      remove :path
      remove :parent_id
    end
  end
end
