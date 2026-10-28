defmodule Bastion.Fleet.Application.Policy do
  import Ecto.Query

  alias Bastion.Access
  alias Bastion.Access.Actor
  alias Bastion.Fleet.{Device, Folder}
  alias Bastion.Fleet.Infrastructure.FolderRecord
  alias Bastion.Repo

  @spec paths([String.t()]) :: [[String.t()]]
  def paths([]), do: []

  def paths(folder_ids) do
    Repo.all(from f in FolderRecord, where: f.id in ^folder_ids, select: f.path)
    |> Enum.map(&FolderRecord.split_path/1)
  end

  @spec device_paths(Device.t()) :: [[String.t()]]
  def device_paths(%Device{folder_ids: ids}), do: paths(ids)

  @spec can?(Actor.t(), String.t(), Device.t(), [[String.t()]] | nil) :: boolean()
  def can?(actor, action, device, paths \\ nil)

  def can?(actor, "view", %Device{status: :pending}, _paths),
    do: Access.can?(actor, "enrollment.approve") or Access.can?(actor, "view")

  def can?(actor, action, %Device{} = device, paths),
    do: Access.can?(actor, action, paths || device_paths(device))

  @spec authorize(Actor.t(), String.t(), Device.t()) :: :ok | {:error, :forbidden}
  def authorize(actor, action, device),
    do: if(can?(actor, action, device), do: :ok, else: {:error, :forbidden})

  @spec authorize_global(Actor.t(), String.t()) :: :ok | {:error, :forbidden}
  def authorize_global(actor, action), do: Access.authorize(actor, action, :global)

  @spec authorize_folder(Actor.t(), String.t(), Folder.t() | String.t() | nil) ::
          :ok | {:error, :forbidden}
  def authorize_folder(actor, action, nil), do: Access.authorize(actor, action, :global)

  def authorize_folder(actor, action, %Folder{path: path}),
    do: Access.authorize(actor, action, [path])

  def authorize_folder(actor, action, path) when is_binary(path),
    do: Access.authorize(actor, action, [FolderRecord.split_path(path)])

  @type visibility :: %{folders: [Folder.t()], dim: MapSet.t(String.t())}

  @spec visible_folders(Actor.t(), [Folder.t()]) :: visibility()
  def visible_folders(actor, folders) do
    if Access.can?(actor, "view") do
      %{folders: folders, dim: MapSet.new()}
    else
      full = Enum.filter(folders, &Access.can?(actor, "view", [&1.path]))
      full_ids = MapSet.new(full, & &1.id)
      ancestors = full |> Enum.flat_map(& &1.path) |> MapSet.new()

      shown = Enum.filter(folders, &(&1.id in full_ids or &1.id in ancestors))
      %{folders: shown, dim: MapSet.difference(ancestors, full_ids)}
    end
  end
end
