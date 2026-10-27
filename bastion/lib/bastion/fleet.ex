defmodule Bastion.Fleet do
  use Boundary,
    top_level?: true,
    deps: [Bastion.Repo, Bastion.Events, Bastion.PKI],
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

  alias Bastion.Fleet.Application.{DeviceCommands, FolderCommands, Queries}
  alias Bastion.Fleet.Domain.{DeviceId, Name}

  defdelegate overview(), to: Queries
  defdelegate list_folders(), to: Queries
  defdelegate get_device(id), to: Queries
  defdelegate find_by_device_id(device_id), to: Queries
  defdelegate list_events(id, limit \\ 200), to: Queries

  def subscribe, do: Bastion.Events.subscribe(:fleet)

  def subscribe(id), do: Bastion.Events.subscribe({:device, id})

  defdelegate submit_request(attrs), to: DeviceCommands
  defdelegate approve(id), to: DeviceCommands
  defdelegate reject(id), to: DeviceCommands
  defdelegate revoke(id), to: DeviceCommands
  defdelegate delete(id), to: DeviceCommands

  defdelegate rename(id, name), to: DeviceCommands
  defdelegate move(id, folder_id), to: DeviceCommands
  defdelegate create_folder(name), to: FolderCommands, as: :create
  defdelegate rename_folder(id, name), to: FolderCommands, as: :rename
  defdelegate delete_folder(id), to: FolderCommands, as: :delete

  defdelegate record_event(id, type, data \\ %{}), to: DeviceCommands
  defdelegate mark_seen(id, attrs), to: DeviceCommands

  defdelegate format_mac(device_id), to: DeviceId
  defdelegate name_max_length(), to: Name, as: :max_length
end
