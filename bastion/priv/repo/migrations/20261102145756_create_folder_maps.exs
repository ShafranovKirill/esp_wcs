defmodule Bastion.Repo.Migrations.CreateFolderMaps do
  use Ecto.Migration

  def change do
    create table(:folder_maps, primary_key: false) do
      add :folder_id, references(:folders, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :background, :string
      add :content_type, :string
      add :width, :integer
      add :height, :integer
    end

    create table(:map_placements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :folder_id, references(:folders, type: :binary_id, on_delete: :delete_all), null: false
      add :device_id, references(:devices, type: :binary_id, on_delete: :delete_all)
      add :child_id, references(:folders, type: :binary_id, on_delete: :delete_all)
      add :x, :float, null: false
      add :y, :float, null: false
    end

    create unique_index(:map_placements, [:folder_id, :device_id])
    create unique_index(:map_placements, [:folder_id, :child_id])

    create constraint(:map_placements, :one_target,
             check: "(device_id IS NULL) <> (child_id IS NULL)"
           )

    create constraint(:map_placements, :coordinates,
             check: "x >= 0 AND x <= 1 AND y >= 0 AND y <= 1"
           )
  end
end
