defmodule Bastion.Maps do
  use Boundary,
    top_level?: true,
    deps: [Bastion.Repo, Bastion.Fleet, Bastion.Events, Bastion.PKI],
    exports: [Events.Changed]

  import Ecto.Query
  alias Bastion.{Fleet, Repo}
  alias Bastion.Maps.Infrastructure.{Image, MapRecord, Placement, Storage, S3}

  def subscribe(id), do: Bastion.Events.subscribe({:map, id})

  def fetch(actor, id) do
    with {:ok, folder} <- authorize(actor, id, "view") do
      overview = Fleet.overview(actor)

      children =
        Enum.filter(
          overview.folders,
          &(&1.parent_id == id and not MapSet.member?(overview.dim, &1.id))
        )

      devices = Map.get(overview.devices, id, [])

      items =
        Enum.map(children, &%{kind: "folder", id: &1.id, name: &1.name}) ++
          Enum.map(devices, &%{kind: "device", id: &1.id, name: &1.name})

      positions = Repo.all(from p in Placement, where: p.folder_id == ^id)

      items =
        Enum.map(items, fn item ->
          pos = Enum.find(positions, &((&1.device_id || &1.child_id) == item.id))
          Map.merge(item, %{x: pos && pos.x, y: pos && pos.y})
        end)

      {:ok,
       %{
         unfiled:
           Enum.filter(
             overview.unfiled,
             &(Fleet.can?(actor, "device.configure", &1) and &1.status == :approved)
           ),
         folder: folder,
         background: Repo.get(MapRecord, id),
         items: items,
         breadcrumbs: Enum.filter(overview.folders, &(&1.id in folder.path)),
         editable: Fleet.can_folder?(actor, "folder.manage", folder)
       }}
    end
  end

  def place(actor, folder_id, "unfiled", id, x, y)
      when is_number(x) and is_number(y) and x >= 0 and x <= 1 and y >= 0 and y <= 1 do
    with {:ok, _} <- authorize(actor, folder_id, "folder.manage") do
      Repo.transaction(fn ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid} ->
            Repo.one(
              from d in "devices",
                where: d.id == type(^uuid, :binary_id),
                select: d.id,
                lock: "FOR UPDATE"
            )

          :error ->
            Repo.rollback(:not_found)
        end

        case Fleet.get_device(id) do
          %{folder_ids: [], status: :approved} ->
            with {:ok, _} <- Fleet.set_folders(actor, id, [folder_id]),
                 {:ok, placed} <- place(actor, folder_id, "device", id, x, y) do
              placed
            else
              {:error, reason} -> Repo.rollback(reason)
            end

          _ ->
            Repo.rollback(:not_found)
        end
      end)
    end
  end

  def place(actor, folder_id, kind, id, x, y)
      when kind in ["device", "folder"] and is_number(x) and is_number(y) and x >= 0 and x <= 1 and
             y >= 0 and y <= 1 do
    with {:ok, _} <- authorize(actor, folder_id, "folder.manage"),
         {:ok, map} <- fetch(actor, folder_id),
         true <- Enum.any?(map.items, &(&1.id == id and &1.kind == kind)) do
      attrs = %{
        folder_id: folder_id,
        device_id: if(kind == "device", do: id),
        child_id: if(kind == "folder", do: id),
        x: x / 1,
        y: y / 1
      }

      target = if kind == "device", do: [:folder_id, :device_id], else: [:folder_id, :child_id]

      result =
        Repo.insert(struct(Placement, attrs),
          on_conflict: {:replace, [:x, :y]},
          conflict_target: target
        )

      changed(folder_id, result)
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  def place(_, _, _, _, _, _), do: {:error, :invalid_position}

  def remove(actor, folder_id, kind, id) do
    with {:ok, _} <- authorize(actor, folder_id, "folder.manage"),
         {:ok, map} <- fetch(actor, folder_id),
         true <- Enum.any?(map.items, &(&1.id == id and &1.kind == kind)) do
      Repo.delete_all(
        from p in Placement,
          where: p.folder_id == ^folder_id and (p.device_id == ^id or p.child_id == ^id)
      )

      changed(folder_id, :ok)
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  def restore_position(actor, folder_id, kind, id, expected, previous) do
    with {:ok, _} <- authorize(actor, folder_id, "folder.manage"),
         {:ok, map} <- fetch(actor, folder_id),
         true <- Enum.any?(map.items, &(&1.id == id and &1.kind == kind)) do
      query =
        from p in Placement,
          where: p.folder_id == ^folder_id and (p.device_id == ^id or p.child_id == ^id)

      count =
        case {expected, previous} do
          {{x, y}, nil} ->
            {count, _} = Repo.delete_all(from p in query, where: p.x == ^x and p.y == ^y)
            count

          {{x, y}, {px, py}} ->
            {count, _} =
              Repo.update_all(from(p in query, where: p.x == ^x and p.y == ^y),
                set: [x: px, y: py]
              )

            count

          {nil, {px, py}} ->
            attrs = %{
              folder_id: folder_id,
              device_id: if(kind == "device", do: id),
              child_id: if(kind == "folder", do: id),
              x: px,
              y: py
            }

            {count, _} = Repo.insert_all(Placement, [attrs], on_conflict: :nothing)
            count

          _ ->
            0
        end

      if count == 1, do: changed(folder_id, :ok), else: {:error, :conflict}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  def set_background(actor, folder_id, path) do
    with {:ok, _} <- authorize(actor, folder_id, "folder.manage"),
         {:ok, image} <- Image.inspect_file(path) do
      hash = Base.encode16(:crypto.hash(:sha256, image.data), case: :lower)
      relative = Path.join(folder_id, hash <> "." <> image.ext)

      with {:ok, stored} <- Storage.put(relative, image) do
        record =
          struct(
            MapRecord,
            Map.merge(stored, %{
              folder_id: folder_id,
              content_type: image.type,
              width: image.width,
              height: image.height
            })
          )

        changed(
          folder_id,
          Repo.insert(record,
            on_conflict:
              {:replace, [:background, :storage, :bucket, :content_type, :width, :height]},
            conflict_target: [:folder_id]
          )
        )
      end
    end
  end

  def clear_background(actor, id) do
    with {:ok, _} <- authorize(actor, id, "folder.manage") do
      Repo.delete_all(from m in MapRecord, where: m.folder_id == ^id)
      changed(id, :ok)
    end
  end

  def background(actor, id) do
    with {:ok, _} <- authorize(actor, id, "view"),
         %MapRecord{background: path, content_type: type} = record when is_binary(path) <-
           Repo.get(MapRecord, id) do
      {:ok, Storage.location(record), type}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  defp authorize(actor, id, action) do
    case Enum.find(Fleet.list_folders(), &(&1.id == id)) do
      nil ->
        {:error, :not_found}

      folder ->
        if Fleet.can_folder?(actor, action, folder), do: {:ok, folder}, else: {:error, :forbidden}
    end
  end

  defp changed(id, result) do
    if result == :ok or match?({:ok, _}, result),
      do: Bastion.Events.publish({:map, id}, %Bastion.Maps.Events.Changed{folder_id: id})

    result
  end

  def read_background(actor, id) do
    with {:ok, location, type} <- background(actor, id),
         {:ok, content} <- Storage.read(location),
         do: {:ok, content, type}
  end

  def setup_storage, do: S3.setup()

  def migrate_local_backgrounds(actor) do
    Repo.all(from m in MapRecord, where: m.storage == "local")
    |> Enum.map(fn record ->
      {record.folder_id, set_background(actor, record.folder_id, Storage.location(record))}
    end)
  end
end
