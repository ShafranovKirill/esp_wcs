defmodule Bastion.Access.Infrastructure.RoleRecord do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "roles" do
    field :name, :string
    field :builtin, :string
    field :actions, {:array, :string}, default: []
    timestamps(type: :utc_datetime)
  end

  def to_domain(%__MODULE__{} = r),
    do: %Bastion.Access.Role{id: r.id, name: r.name, builtin: r.builtin, actions: r.actions}

  def changeset(record, attrs) do
    record
    |> Ecto.Changeset.change(attrs)
    |> Ecto.Changeset.unique_constraint(:name, name: :roles_name_index)
  end
end

defmodule Bastion.Access.Infrastructure.GroupRecord do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "groups" do
    field :name, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> Ecto.Changeset.change(attrs)
    |> Ecto.Changeset.unique_constraint(:name, name: :groups_name_index)
  end
end

defmodule Bastion.Access.Infrastructure.GrantRecord do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "grants" do
    field :role_id, :binary_id
    field :user_id, :binary_id
    field :group_id, :binary_id
    field :folder_id, :binary_id
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def to_domain(%__MODULE__{} = r) do
    %Bastion.Access.Grant{
      id: r.id,
      role_id: r.role_id,
      user_id: r.user_id,
      group_id: r.group_id,
      folder_id: r.folder_id
    }
  end

  def changeset(record, attrs) do
    record
    |> Ecto.Changeset.change(attrs)
    |> Ecto.Changeset.unique_constraint(:role_id, name: :grants_unique_index)
    |> Ecto.Changeset.foreign_key_constraint(:folder_id)
    |> Ecto.Changeset.foreign_key_constraint(:user_id)
    |> Ecto.Changeset.foreign_key_constraint(:group_id)
  end
end
