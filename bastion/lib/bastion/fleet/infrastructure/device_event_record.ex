defmodule Bastion.Fleet.Infrastructure.DeviceEventRecord do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "device_events" do
    field :device_id, :binary_id
    field :type, Ecto.Enum, values: Bastion.Fleet.DeviceEvent.types()
    field :data, :map, default: %{}
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def to_domain(%__MODULE__{} = r),
    do: %Bastion.Fleet.DeviceEvent{id: r.id, type: r.type, data: r.data, at: r.inserted_at}
end
