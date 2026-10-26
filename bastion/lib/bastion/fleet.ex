defmodule Bastion.Fleet do
  @moduledoc """
  Контекст Fleet — устройства и папки (`docs/bastion.md`, «Устройство»).

  Заявки приходят от контекста Link (WCS Link), решения принимает администратор.
  Каждое изменение пишется в журнал устройства и публикуется событием
  (`Bastion.Fleet.Events`).
  """
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

  # ---- чтение ----

  @doc "Главная: заявки, устройства по папкам и без папки"
  defdelegate overview(), to: Queries
  defdelegate list_folders(), to: Queries
  defdelegate get_device(id), to: Queries
  defdelegate find_by_device_id(device_id), to: Queries
  defdelegate list_events(id, limit \\ 200), to: Queries

  @doc "Подписаться на изменения всех устройств и папок (`:fleet`)"
  def subscribe, do: Bastion.Events.subscribe(:fleet)

  @doc "Подписаться на изменения одного устройства"
  def subscribe(id), do: Bastion.Events.subscribe({:device, id})

  # ---- заявки и решения ----

  @doc "Заявка устройства (от WCS Link)"
  defdelegate submit_request(attrs), to: DeviceCommands
  defdelegate approve(id), to: DeviceCommands
  defdelegate reject(id), to: DeviceCommands
  defdelegate revoke(id), to: DeviceCommands
  @doc "Удалить можно только отозванное устройство"
  defdelegate delete(id), to: DeviceCommands

  # ---- имя, папки ----

  defdelegate rename(id, name), to: DeviceCommands
  @doc "Перенести в папку; `nil` — «Без папки»"
  defdelegate move(id, folder_id), to: DeviceCommands
  defdelegate create_folder(name), to: FolderCommands, as: :create
  defdelegate rename_folder(id, name), to: FolderCommands, as: :rename
  defdelegate delete_folder(id), to: FolderCommands, as: :delete

  # ---- для других контекстов ----

  @doc "Запись в журнал устройства (подключение, консоль, команды)"
  defdelegate record_event(id, type, data \\ %{}), to: DeviceCommands
  @doc "Устройство было на связи: время, IP, версия прошивки"
  defdelegate mark_seen(id, attrs), to: DeviceCommands

  # ---- вспомогательное ----

  @doc "MAC из ID устройства: `7c:2c:67:8c:85:80`"
  defdelegate format_mac(device_id), to: DeviceId
  @doc "Максимальная длина имени устройства и папки"
  defdelegate name_max_length(), to: Name, as: :max_length
end
