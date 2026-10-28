defmodule Bastion.Fleet do
  use Boundary,
    top_level?: true,
    deps: [Bastion.Repo, Bastion.Events, Bastion.PKI, Bastion.Access],
    exports: [
      Device,
      Folder,
      DeviceEvent,
      Events.DeviceRequested,
      Events.DeviceApproved,
      Events.DeviceRevoked,
      Events.DeviceChanged,
      Events.FoldersChanged
    ]

  alias Bastion.Fleet.Application.{DeviceCommands, FolderCommands, Policy, Queries}
  alias Bastion.Fleet.Domain.{DeviceId, Name}

  defdelegate overview(actor), to: Queries
  defdelegate list_folders(), to: Queries
  defdelegate visible_folders(actor), to: Queries
  defdelegate fetch_device(actor, id), to: Queries
  defdelegate get_device(id), to: Queries
  defdelegate find_by_device_id(device_id), to: Queries
  defdelegate list_events(id, limit \\ 200), to: Queries

  def subscribe, do: Bastion.Events.subscribe(:fleet)

  def subscribe(id), do: Bastion.Events.subscribe({:device, id})

  defdelegate submit_request(attrs), to: DeviceCommands
  defdelegate approve(actor, id, device_code), to: DeviceCommands
  defdelegate reject(actor, id), to: DeviceCommands
  defdelegate revoke(actor, id), to: DeviceCommands
  defdelegate delete(actor, id), to: DeviceCommands

  defdelegate rename(actor, id, name), to: DeviceCommands
  defdelegate set_folders(actor, id, folder_ids), to: DeviceCommands
  defdelegate create_folder(actor, name, parent_id \\ nil), to: FolderCommands, as: :create
  defdelegate rename_folder(actor, id, name), to: FolderCommands, as: :rename
  defdelegate move_folder(actor, id, parent_id), to: FolderCommands, as: :move
  defdelegate delete_folder(actor, id), to: FolderCommands, as: :delete

  @spec can?(Bastion.Access.Actor.t(), String.t(), Bastion.Fleet.Device.t()) :: boolean()
  def can?(actor, action, device), do: Policy.can?(actor, action, device)

  @spec can_folder?(Bastion.Access.Actor.t(), String.t(), Bastion.Fleet.Folder.t() | nil) ::
          boolean()
  def can_folder?(actor, action, folder),
    do: Policy.authorize_folder(actor, action, folder) == :ok

  @spec authorize(Bastion.Access.Actor.t(), String.t(), String.t()) ::
          :ok | {:error, :forbidden | :not_found}
  def authorize(actor, action, id) do
    case get_device(id) do
      nil -> {:error, :not_found}
      device -> Policy.authorize(actor, action, device)
    end
  end

  defdelegate record_event(id, type, data \\ %{}, actor \\ nil), to: DeviceCommands
  defdelegate mark_seen(id, attrs), to: DeviceCommands

  defdelegate format_mac(device_id), to: DeviceId
  defdelegate name_max_length(), to: Name, as: :max_length
  defdelegate max_devices(), to: Bastion.Fleet.Device
end
