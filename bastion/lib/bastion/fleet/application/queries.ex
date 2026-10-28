defmodule Bastion.Fleet.Application.Queries do
  import Ecto.Query

  alias Bastion.Access.Actor
  alias Bastion.Fleet.Application.Policy
  alias Bastion.Fleet.{Device, DeviceEvent, Folder}
  alias Bastion.Fleet.Infrastructure.{DeviceEventRecord, DeviceRecord, FolderRecord}
  alias Bastion.Repo

  @type overview :: %{
          requests: [Device.t()],
          folders: [Folder.t()],
          dim: MapSet.t(String.t()),
          devices: %{String.t() => [Device.t()]},
          unfiled: [Device.t()],
          total: non_neg_integer()
        }

  @spec overview(Actor.t()) :: overview()
  def overview(actor) do
    %{folders: folders, dim: dim} = Policy.visible_folders(actor, list_folders())
    full = folders |> MapSet.new(& &1.id) |> MapSet.difference(dim)

    devices =
      from(d in DeviceRecord, order_by: fragment("lower(?)", d.name), preload: :folders)
      |> visible_to(actor)
      |> Repo.all()
      |> Enum.map(&DeviceRecord.to_domain/1)
      |> Enum.map(fn d -> %{d | folder_ids: Enum.filter(d.folder_ids, &(&1 in full))} end)

    {requests, devices} = Enum.split_with(devices, &(&1.status == :pending))

    requests =
      if Bastion.Access.can?(actor, "enrollment.approve"), do: requests, else: []

    by_folder =
      devices
      |> Enum.flat_map(fn d -> Enum.map(d.folder_ids, &{&1, d}) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    %{
      requests: Enum.sort_by(requests, & &1.requested_at, {:desc, DateTime}),
      folders: folders,
      dim: dim,
      devices: by_folder,
      unfiled: Enum.filter(devices, &(&1.folder_ids == [])),
      total: length(devices)
    }
  end

  defp visible_to(query, actor) do
    if Bastion.Access.can?(actor, "view") do
      query
    else
      ids = Actor.granted_folder_ids(actor, "view")

      patterns =
        Repo.all(from f in FolderRecord, where: f.id in ^ids, select: f.path)
        |> Enum.flat_map(&[&1, &1 <> "/%"])

      scoped =
        from df in "device_folders",
          join: f in FolderRecord,
          on: f.id == df.folder_id,
          where: fragment("? LIKE ANY(?)", f.path, ^patterns),
          select: type(df.device_id, :binary_id)

      if Bastion.Access.can?(actor, "enrollment.approve"),
        do: where(query, [d], d.id in subquery(scoped) or d.status == :pending),
        else: where(query, [d], d.id in subquery(scoped))
    end
  end

  @spec list_folders() :: [Folder.t()]
  def list_folders do
    Repo.all(FolderRecord)
    |> Enum.map(&FolderRecord.to_domain/1)
    |> Folder.tree()
    |> Folder.flatten()
  end

  @spec visible_folders(Actor.t()) :: Policy.visibility()
  def visible_folders(actor), do: Policy.visible_folders(actor, list_folders())

  @spec fetch_device(Actor.t(), String.t()) :: Device.t() | nil
  def fetch_device(actor, id) do
    with %Device{} = device <- get_device(id),
         true <- Policy.can?(actor, "view", device) do
      device
    else
      _ -> nil
    end
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
