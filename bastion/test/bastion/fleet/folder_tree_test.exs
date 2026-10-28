defmodule Bastion.Fleet.FolderTreeTest do
  use Bastion.DataCase, async: true

  import Bastion.FleetFixtures

  alias Bastion.Fleet
  alias Bastion.Fleet.Folder

  defp folder(id), do: Enum.find(Fleet.list_folders(), &(&1.id == id))

  test "вложенность, порядок дерева и полный путь" do
    {:ok, b} = Fleet.create_folder(system(), "Здание Б")
    {:ok, a} = Fleet.create_folder(system(), "Здание А")
    {:ok, floor} = Fleet.create_folder(system(), "Этаж 3", a.id)
    {:ok, room} = Fleet.create_folder(system(), "Кабинет 301", floor.id)

    assert Enum.map(Fleet.list_folders(), & &1.name) ==
             ["Здание А", "Этаж 3", "Кабинет 301", "Здание Б"]

    assert room.path == [a.id, floor.id, room.id]
    assert Folder.inside?(room, a)
    refute Folder.inside?(room, b)

    by_id = Map.new(Fleet.list_folders(), &{&1.id, &1})
    assert Folder.full_name(room, by_id) == "Здание А / Этаж 3 / Кабинет 301"
  end

  test "имя уникально среди соседей, но не во всём дереве" do
    {:ok, a} = Fleet.create_folder(system(), "А")
    {:ok, b} = Fleet.create_folder(system(), "Б")
    assert {:ok, _} = Fleet.create_folder(system(), "Этаж 1", a.id)
    assert {:ok, _} = Fleet.create_folder(system(), "Этаж 1", b.id)
    assert {:error, :name_taken} = Fleet.create_folder(system(), "этаж 1", a.id)
    assert {:error, :name_taken} = Fleet.create_folder(system(), "а")
    assert {:error, :folder_not_found} = Fleet.create_folder(system(), "X", Ecto.UUID.generate())
  end

  test "не глубже 8 уровней" do
    deepest =
      Enum.reduce(1..8, nil, fn n, parent ->
        {:ok, f} = Fleet.create_folder(system(), "L#{n}", parent && parent.id)
        f
      end)

    assert Folder.depth(deepest) == 8
    assert {:error, :folder_too_deep} = Fleet.create_folder(system(), "L9", deepest.id)
  end

  test "перенос поддерева пересчитывает пути; внутрь себя нельзя; глубина проверяется" do
    {:ok, a} = Fleet.create_folder(system(), "А")
    {:ok, b} = Fleet.create_folder(system(), "Б")
    {:ok, floor} = Fleet.create_folder(system(), "Этаж", a.id)
    {:ok, room} = Fleet.create_folder(system(), "Кабинет", floor.id)

    assert {:error, :folder_into_itself} = Fleet.move_folder(system(), a.id, room.id)
    assert {:error, :folder_into_itself} = Fleet.move_folder(system(), a.id, a.id)

    assert {:ok, moved} = Fleet.move_folder(system(), floor.id, b.id)
    assert moved.path == [b.id, floor.id]
    assert folder(room.id).path == [b.id, floor.id, room.id]

    assert {:ok, top} = Fleet.move_folder(system(), floor.id, nil)
    assert top.parent_id == nil
    assert folder(room.id).path == [floor.id, room.id]

    chain =
      Enum.reduce(1..7, nil, fn n, parent ->
        {:ok, f} = Fleet.create_folder(system(), "C#{n}", parent && parent.id)
        f
      end)

    assert {:error, :folder_too_deep} = Fleet.move_folder(system(), floor.id, chain.id)

    {:ok, _} = Fleet.create_folder(system(), "Кабинет", b.id)
    assert {:error, :name_taken} = Fleet.move_folder(system(), room.id, b.id)
  end

  test "удаление: только пустая папка" do
    {:ok, a} = Fleet.create_folder(system(), "А")
    {:ok, floor} = Fleet.create_folder(system(), "Этаж", a.id)
    assert {:error, :folder_not_empty} = Fleet.delete_folder(system(), a.id)

    device = approved_device()
    {:ok, _} = Fleet.set_folders(system(), device.id, [floor.id])
    assert {:error, :folder_not_empty} = Fleet.delete_folder(system(), floor.id)

    {:ok, _} = Fleet.set_folders(system(), device.id, [])
    assert :ok = Fleet.delete_folder(system(), floor.id)
    assert :ok = Fleet.delete_folder(system(), a.id)
    assert {:error, :folder_not_found} = Fleet.delete_folder(system(), a.id)
  end

  test "устройство в нескольких папках" do
    {:ok, room} = Fleet.create_folder(system(), "Серверная")
    {:ok, core} = Fleet.create_folder(system(), "Ядро сети")
    device = approved_device()

    {:ok, device} = Fleet.set_folders(system(), device.id, [room.id, core.id, room.id])
    assert Enum.sort(device.folder_ids) == Enum.sort([room.id, core.id])

    overview = Fleet.overview(system())
    assert [%{id: id}] = overview.devices[room.id]
    assert [%{id: ^id}] = overview.devices[core.id]
    assert overview.total == 1
    assert Fleet.get_device(device.id).folder_ids == device.folder_ids
  end
end
