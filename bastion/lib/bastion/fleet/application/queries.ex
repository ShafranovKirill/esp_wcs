defmodule Bastion.Fleet.Application.Queries do
  import Ecto.Query

  alias Bastion.Fleet.{Device, DeviceEvent, Folder}
  alias Bastion.Fleet.Infrastructure.{DeviceEventRecord, DeviceRecord, FolderRecord}
  alias Bastion.Repo

  @type overview :: %{
          requests: [Device.t()],
          folders: [Folder.t()],
          devices: %{String.t() => [Device.t()]},
          unfiled: [Device.t()],
          total: non_neg_integer()
        }

  @spec overview() :: overview()
  def overview do
    devices =
      Repo.all(from d in DeviceRecord, order_by: fragment("lower(?)", d.name), preload: :folders)
      |> Enum.map(&DeviceRecord.to_domain/1)

    {requests, devices} = Enum.split_with(devices, &(&1.status == :pending))

    by_folder =
      devices
      |> Enum.flat_map(fn d -> Enum.map(d.folder_ids, &{&1, d}) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    %{
      requests: Enum.sort_by(requests, & &1.requested_at, {:desc, DateTime}),
      folders: list_folders(),
      devices: by_folder,
      unfiled: Enum.filter(devices, &(&1.folder_ids == [])),
      total: length(devices)
    }
  end

  @spec list_folders() :: [Folder.t()]
  def list_folders do
    Repo.all(FolderRecord)
    |> Enum.map(&FolderRecord.to_domain/1)
    |> Folder.tree()
    |> Folder.flatten()
  end

  @spec get_device(String.t()) :: Device.t() | nil
  def get_device(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %DeviceRecord{} = record <- Repo.get(DeviceRecord, uuid) do
      record |> Repo.preload(:folders) |> DeviceRecord.to_domain()
    else
      _ -> nil
    end
  end

  @spec find_by_device_id(String.t()) :: Device.t() | nil
  def find_by_device_id(device_id) do
    case Repo.get_by(DeviceRecord, device_id: String.downcase(device_id)) do
      nil -> nil
      record -> record |> Repo.preload(:folders) |> DeviceRecord.to_domain()
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
