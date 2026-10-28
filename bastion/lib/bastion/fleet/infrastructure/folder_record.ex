defmodule Bastion.Fleet.Infrastructure.FolderRecord do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "folders" do
    field :name, :string
    field :path, :string
    belongs_to :parent, __MODULE__
    timestamps(type: :utc_datetime)
  end

  @spec split_path(String.t()) :: [String.t()]
  def split_path(path), do: String.split(path, "/")

  def to_domain(%__MODULE__{} = r) do
    %Bastion.Fleet.Folder{
      id: r.id,
      name: r.name,
      parent_id: r.parent_id,
      path: split_path(r.path)
    }
  end

  def changeset(record, attrs) do
    record
    |> Ecto.Changeset.change(attrs)
    |> Ecto.Changeset.unique_constraint(:name, name: :folders_sibling_name_index)
    |> Ecto.Changeset.foreign_key_constraint(:parent_id)
  end
end
