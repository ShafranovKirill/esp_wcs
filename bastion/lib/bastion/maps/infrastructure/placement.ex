defmodule Bastion.Maps.Infrastructure.Placement do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "map_placements" do
    field :folder_id, :binary_id
    field :device_id, :binary_id
    field :child_id, :binary_id
    field :x, :float
    field :y, :float
  end
end
