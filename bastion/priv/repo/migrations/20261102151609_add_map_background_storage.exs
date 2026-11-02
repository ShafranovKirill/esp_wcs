defmodule Bastion.Repo.Migrations.AddMapBackgroundStorage do
  use Ecto.Migration

  def change do
    alter table(:folder_maps) do
      add :storage, :string, null: false, default: "local"
      add :bucket, :string
    end
  end
end
