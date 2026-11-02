defmodule Bastion.Maps.Infrastructure.MapRecord do
  use Ecto.Schema
  @primary_key {:folder_id, :binary_id, autogenerate: false}
  schema "folder_maps" do
    field :storage, :string, default: "local"
    field :bucket, :string
    field :background, :string
    field :content_type, :string
    field :width, :integer
    field :height, :integer
  end
end
