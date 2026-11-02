defmodule Bastion.MapsTest do
  use Bastion.DataCase, async: false
  import Bastion.FleetFixtures
  alias Bastion.{Fleet, Maps}
  alias Bastion.Access.Actor

  setup do
    {:ok, folder} = Fleet.create_folder(system(), "Campus")
    {:ok, child} = Fleet.create_folder(system(), "Building", folder.id)
    {:ok, other} = Fleet.create_folder(system(), "Other")
    device = approved_device()
    {:ok, device} = Fleet.set_folders(system(), device.id, [folder.id, other.id])
    %{folder: folder, child: child, other: other, device: device}
  end

  test "positions are independent on each map and persist", c do
    assert {:ok, _} = Maps.place(system(), c.folder.id, "device", c.device.id, 0.2, 0.7)
    assert {:ok, _} = Maps.place(system(), c.other.id, "device", c.device.id, 0.9, 0.1)
    assert {:ok, _} = Maps.place(system(), c.folder.id, "folder", c.child.id, 0.4, 0.5)
    assert {:ok, map} = Maps.fetch(system(), c.folder.id)
    assert Enum.find(map.items, &(&1.id == c.device.id)).x == 0.2
    assert Enum.find(map.items, &(&1.id == c.child.id)).y == 0.5
    assert {:ok, other} = Maps.fetch(system(), c.other.id)
    assert hd(other.items).x == 0.9
    assert :ok = Maps.remove(system(), c.folder.id, "device", c.device.id)
    assert {:ok, map} = Maps.fetch(system(), c.folder.id)
    assert is_nil(Enum.find(map.items, &(&1.id == c.device.id)).x)
  end

  test "rejects out of bounds and targets outside the folder", c do
    assert {:error, :invalid_position} =
             Maps.place(system(), c.folder.id, "device", c.device.id, -0.1, 1)

    assert {:error, :invalid_position} =
             Maps.place(system(), c.folder.id, "device", c.device.id, "0.5", 1)

    assert {:error, :not_found} =
             Maps.place(system(), c.folder.id, "folder", c.other.id, 0.5, 0.5)

    assert {:ok, _} = Maps.place(system(), c.folder.id, "folder", c.child.id, 0, 1)
    assert {:ok, _} = Fleet.move_folder(system(), c.child.id, c.other.id)
    assert {:ok, map} = Maps.fetch(system(), c.folder.id)
    refute Enum.any?(map.items, &(&1.id == c.child.id))
  end

  test "view permission does not allow mutations or background access elsewhere", c do
    viewer = %Actor{folders: %{c.folder.id => MapSet.new(["view"])}}
    assert {:ok, %{editable: false}} = Maps.fetch(viewer, c.folder.id)
    assert {:error, :forbidden} = Maps.place(viewer, c.folder.id, "device", c.device.id, 0.5, 0.5)
    assert {:error, :forbidden} = Maps.remove(viewer, c.folder.id, "device", c.device.id)
    assert {:error, :forbidden} = Maps.set_background(viewer, c.folder.id, "/does/not/exist")
    assert {:error, :forbidden} = Maps.clear_background(viewer, c.folder.id)
    assert {:error, :forbidden} = Maps.background(viewer, c.other.id)
    assert {:error, :forbidden} = Maps.fetch(%Actor{}, c.folder.id)
    assert {:error, :not_found} = Maps.fetch(system(), "invalid")
  end

  test "only direct children appear; ancestor-only visibility cannot read its map", c do
    {:ok, grandchild} = Fleet.create_folder(system(), "Room", c.child.id)
    assert {:ok, map} = Maps.fetch(system(), c.folder.id)
    refute Enum.any?(map.items, &(&1.id == grandchild.id))
    viewer = %Actor{folders: %{c.child.id => MapSet.new(["view"])}}
    assert {:error, :forbidden} = Maps.fetch(viewer, c.folder.id)
    assert {:ok, _} = Maps.fetch(viewer, c.child.id)
  end

  test "background inspection, persistence and replacement preserve coordinates", c do
    path = Path.join(System.tmp_dir!(), "map-#{c.folder.id}.png")

    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
      )

    File.write!(path, png)
    on_exit(fn -> File.rm(path) end)
    assert {:ok, _} = Maps.place(system(), c.folder.id, "device", c.device.id, 0.25, 0.75)
    assert {:ok, _} = Maps.set_background(system(), c.folder.id, path)
    assert {:ok, stored, "image/png"} = Maps.background(system(), c.folder.id)
    on_exit(fn -> File.rm_rf(Path.dirname(stored)) end)
    assert File.read!(stored) == png
    assert {:ok, %{background: %{width: 1, height: 1}}} = Maps.fetch(system(), c.folder.id)
    File.write!(path, "<svg><script>alert(1)</script></svg>")
    assert {:error, :invalid_image} = Maps.set_background(system(), c.folder.id, path)
    File.write!(path, <<137, "PNG", 13, 10, 26, 10, 13::32, "IHDR", 8001::32, 1::32>>)
    assert {:error, :invalid_image} = Maps.set_background(system(), c.folder.id, path)
    assert :ok = Maps.clear_background(system(), c.folder.id)
    assert {:ok, map} = Maps.fetch(system(), c.folder.id)
    assert is_nil(map.background)
    assert Enum.find(map.items, &(&1.id == c.device.id)).x == 0.25
  end

  test "placing an unassigned device also assigns its folder atomically", c do
    device = approved_device()

    assert {:error, :forbidden} =
             Maps.place(
               %Actor{folders: %{c.folder.id => MapSet.new(["view", "folder.manage"])}},
               c.folder.id,
               "unfiled",
               device.id,
               0.3,
               0.5
             )

    assert Fleet.get_device(device.id).folder_ids == []

    assert {:error, :invalid_position} =
             Maps.place(system(), c.folder.id, "unfiled", device.id, -1, 0.5)

    assert Fleet.get_device(device.id).folder_ids == []
    assert {:ok, _} = Maps.place(system(), c.folder.id, "unfiled", device.id, 0.3, 0.5)
    assert Fleet.get_device(device.id).folder_ids == [c.folder.id]
    assert {:ok, map} = Maps.fetch(system(), c.folder.id)
    assert Enum.find(map.items, &(&1.id == device.id)).x == 0.3
    assert {:error, :not_found} = Maps.place(system(), c.other.id, "unfiled", device.id, 0.5, 0.5)
    assert Fleet.get_device(device.id).folder_ids == [c.folder.id]
  end
end
