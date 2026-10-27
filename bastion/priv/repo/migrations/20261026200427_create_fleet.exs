defmodule Bastion.Repo.Migrations.CreateFleet do
  use Ecto.Migration

  def change do
    create table(:folders, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:folders, ["lower(name)"], name: :folders_name_index)

    create table(:devices, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :device_id, :string, size: 12, null: false
      add :name, :string, null: false
      add :status, :string, null: false
      add :folder_id, references(:folders, type: :binary_id, on_delete: :nilify_all)

      add :device_code, :string, null: false
      add :csr_pem, :text
      add :certificate_pem, :text
      add :certificate_serial, :string
      add :certificate_not_after, :utc_datetime

      add :firmware_version, :string
      add :last_ip, :string
      add :last_seen_at, :utc_datetime
      add :requested_at, :utc_datetime, null: false
      add :approved_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:devices, [:device_id])
    create unique_index(:devices, ["lower(name)"], name: :devices_name_index)
    create index(:devices, [:folder_id])
    create index(:devices, [:status])

    create constraint(:devices, :status_valid,
             check: "status IN ('pending', 'approved', 'revoked')"
           )

    create table(:device_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :device_id, references(:devices, type: :binary_id, on_delete: :delete_all), null: false
      add :type, :string, null: false
      add :data, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:device_events, [:device_id, :inserted_at])
  end
end
