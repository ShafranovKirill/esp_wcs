defmodule Bastion.Fleet.Infrastructure.FolderRecord do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "folders" do
    field :name, :string
    timestamps(type: :utc_datetime)
  end

  def to_domain(%__MODULE__{id: id, name: name}), do: %Bastion.Fleet.Folder{id: id, name: name}

  def changeset(record, name) do
    record
    |> Ecto.Changeset.change(name: name)
    |> Ecto.Changeset.unique_constraint(:name, name: :folders_name_index)
  end
end
