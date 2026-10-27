defmodule Bastion.Fleet.Application.Queries do
  import Ecto.Query

  alias Bastion.Fleet.{Device, DeviceEvent, Folder}
  alias Bastion.Fleet.Infrastructure.{DeviceEventRecord, DeviceRecord, FolderRecord}
  alias Bastion.Repo

  @type overview :: %{
          requests: [Device.t()],
          folders: [{Folder.t(), [Device.t()]}],
          unfiled: [Device.t()]
        }

  @spec overview() :: overview()
  def overview do
    devices =
      Repo.all(from d in DeviceRecord, order_by: fragment("lower(?)", d.name))
      |> Enum.map(&DeviceRecord.to_domain/1)

    {requests, devices} = Enum.split_with(devices, &(&1.status == :pending))
    by_folder = Enum.group_by(devices, & &1.folder_id)

    %{
      requests: Enum.sort_by(requests, & &1.requested_at, {:desc, DateTime}),
      folders: Enum.map(list_folders(), &{&1, Map.get(by_folder, &1.id, [])}),
      unfiled: Map.get(by_folder, nil, [])
    }
  end

  @spec list_folders() :: [Folder.t()]
  def list_folders do
    Repo.all(from f in FolderRecord, order_by: fragment("lower(?)", f.name))
    |> Enum.map(&FolderRecord.to_domain/1)
  end

  @spec get_device(String.t()) :: Device.t() | nil
  def get_device(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %DeviceRecord{} = record <- Repo.get(DeviceRecord, uuid) do
      DeviceRecord.to_domain(record)
    else
      _ -> nil
    end
  end

  @spec find_by_device_id(String.t()) :: Device.t() | nil
  def find_by_device_id(device_id) do
    case Repo.get_by(DeviceRecord, device_id: String.downcase(device_id)) do
      nil -> nil
      record -> DeviceRecord.to_domain(record)
    end
  end

  @spec list_events(String.t(), pos_integer()) :: [DeviceEvent.t()]
  def list_events(id, limit \\ 200) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Repo.all(
          from e in DeviceEventRecord,
            where: e.device_id == ^uuid,
            order_by: [desc: e.inserted_at],
            limit: ^limit
        )
        |> Enum.map(&DeviceEventRecord.to_domain/1)

      :error ->
        []
    end
  end
end
