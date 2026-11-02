defmodule Bastion.Demo.Campus do
  alias Bastion.{Access, Fleet, Maps}

  def seed(photo_dir) do
    actor = Access.system()
    campus = folder(actor, "Территория", nil)
    background(actor, campus, photo_dir, "campus-overview.png")

    for {letter, code, index} <- [{"А", "a", 0}, {"Б", "b", 1}] do
      building =
        case Enum.find(
               Fleet.list_folders(),
               &(&1.name == "Здание #{letter}" and &1.parent_id == nil)
             ) do
          nil ->
            folder(actor, "Здание #{letter}", campus.id)

          existing ->
            {:ok, moved} = Fleet.move_folder(actor, existing.id, campus.id)
            moved
        end

      background(actor, building, photo_dir, "building-exterior.jpg")
      position(actor, campus, "folder", building.id, 0.3 + index * 0.4, 0.5)

      for floor_number <- 1..4 do
        floor = folder(actor, "Этаж #{floor_number}", building.id)

        for legacy <- Fleet.list_folders(),
            legacy.parent_id == floor.id,
            String.starts_with?(legacy.name, "Серверная") do
          archive = folder(actor, "Ранее созданные примеры", nil)
          {:ok, _} = Fleet.move_folder(actor, legacy.id, archive.id)
        end

        background(actor, floor, photo_dir, "floor-plan.jpg")
        position(actor, building, "folder", floor.id, 0.2 + (floor_number - 1) * 0.2, 0.6)

        for room_number <- 1..3 do
          room = folder(actor, "Кабинет #{floor_number}0#{room_number}", floor.id)
          background(actor, room, photo_dir, "office-interior.jpg")
          position(actor, floor, "folder", room.id, 0.25 * room_number, 0.5)
          existing = Map.get(Fleet.overview(actor).devices, room.id, [])

          if length(existing) < 3 do
            for n <- (length(existing) + 1)..3 do
              id = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)

              csr =
                X509.PrivateKey.new_ec(:secp256r1)
                |> X509.CSR.new("/CN=#{id}")
                |> X509.CSR.to_pem()

              {:ok, :pending} =
                Fleet.submit_request(%{
                  device_id: id,
                  name: "sw-#{code}-#{floor_number}0#{room_number}-#{n}",
                  csr_pem: csr,
                  firmware_version: "demo",
                  ip: "192.168.10.#{10 + floor_number * 9 + room_number * 3 + n}"
                })

              d = Fleet.find_by_device_id(id)
              {:ok, _} = Fleet.approve(actor, d.id, d.device_code)
              {:ok, _} = Fleet.set_folders(actor, d.id, [room.id])
            end
          end

          Fleet.overview(actor).devices
          |> Map.get(room.id, [])
          |> Enum.with_index()
          |> Enum.each(fn {d, n} ->
            position(actor, room, "device", d.id, 0.25 * (n + 1), 0.55)
          end)
        end
      end
    end

    {:ok, campus}
  end

  def refresh_covers(photo_dir) do
    actor = Access.system()
    campus = Enum.find(Fleet.list_folders(), &(&1.name == "Территория" and is_nil(&1.parent_id)))

    for folder <- Fleet.list_folders(), campus.id in folder.path do
      file =
        case length(folder.path) - length(campus.path) do
          0 -> "campus-overview.png"
          1 -> "building-exterior.jpg"
          2 -> "floor-plan.jpg"
          _ -> "office-interior.jpg"
        end

      {:ok, _} = Maps.set_background(actor, folder.id, Path.join(photo_dir, file))
    end

    :ok
  end

  defp folder(actor, name, parent) do
    Enum.find(Fleet.list_folders(), &(&1.name == name and &1.parent_id == parent)) ||
      case Fleet.create_folder(actor, name, parent) do
        {:ok, folder} -> folder
      end
  end

  defp background(actor, folder, dir, name) do
    {:ok, map} = Maps.fetch(actor, folder.id)

    if is_nil(map.background) do
      {:ok, _} = Maps.set_background(actor, folder.id, Path.join(dir, name))
    end
  end

  defp position(actor, folder, kind, id, x, y) do
    {:ok, map} = Maps.fetch(actor, folder.id)

    case Enum.find(map.items, &(&1.id == id)) do
      %{x: nil} -> {:ok, _} = Maps.place(actor, folder.id, kind, id, x, y)
      _ -> :ok
    end
  end
end
