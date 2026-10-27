defmodule Bastion.Fleet.Infrastructure.DeviceRecord do
  use Ecto.Schema

  alias Bastion.Fleet.Device

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @fields ~w(device_id name status folder_id device_code csr_pem certificate_pem certificate_serial
             certificate_not_after firmware_version last_ip last_seen_at requested_at approved_at revoked_at)a

  schema "devices" do
    field :device_id, :string
    field :name, :string
    field :status, Ecto.Enum, values: [:pending, :approved, :revoked]
    field :device_code, :string
    field :csr_pem, :string
    field :certificate_pem, :string
    field :certificate_serial, :string
    field :certificate_not_after, :utc_datetime
    field :firmware_version, :string
    field :last_ip, :string
    field :last_seen_at, :utc_datetime
    field :requested_at, :utc_datetime
    field :approved_at, :utc_datetime
    field :revoked_at, :utc_datetime
    belongs_to :folder, Bastion.Fleet.Infrastructure.FolderRecord

    timestamps(type: :utc_datetime)
  end

  def to_domain(%__MODULE__{} = r), do: struct(Device, Map.take(r, [:id | @fields]))

  def changeset(%__MODULE__{} = record, %Device{} = device) do
    record
    |> Ecto.Changeset.change(Map.take(device, @fields))
    |> Ecto.Changeset.unique_constraint(:name, name: :devices_name_index)
    |> Ecto.Changeset.unique_constraint(:device_id)
    |> Ecto.Changeset.foreign_key_constraint(:folder_id)
  end
end
