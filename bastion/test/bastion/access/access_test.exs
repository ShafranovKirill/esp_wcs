defmodule Bastion.AccessTest do
  use Bastion.DataCase, async: false

  import Bastion.FleetFixtures

  alias Bastion.{Access, Accounts, Fleet}
  alias Bastion.Access.Events.GrantsChanged

  defp role(builtin), do: Enum.find(Access.list_roles(), &(&1.builtin == builtin))

  defp user(name) do
    {:ok, user, _password} = Accounts.create_user(system(), name)
    user
  end

  defp actor(user), do: Access.actor(user)

  defp grant!(user_or_group, builtin, folder) do
    who =
      case user_or_group do
        %Bastion.Accounts.User{id: id} -> %{user_id: id}
        %Bastion.Access.Group{id: id} -> %{group_id: id}
      end

    {:ok, grant} =
      Access.grant(
        system(),
        Map.merge(who, %{role_id: role(builtin).id, folder_id: folder && folder.id})
      )

    grant
  end

  defp device_in(folders) do
    device = approved_device()
    {:ok, device} = Fleet.set_folders(system(), device.id, Enum.map(folders, & &1.id))
    device
  end

  setup do
    {:ok, building} = Fleet.create_folder(system(), "Здание А")
    {:ok, floor} = Fleet.create_folder(system(), "Этаж 3", building.id)
    {:ok, room} = Fleet.create_folder(system(), "Серверная 301", floor.id)
    {:ok, core} = Fleet.create_folder(system(), "Ядро сети")
    %{building: building, floor: floor, room: room, core: core}
  end

  test "заводские роли и зависимые действия" do
    assert role("viewer").actions == ["view", "console.read"]
    assert role("superadmin").actions == ["superadmin"]

    assert Access.normalize_actions(["console.write"]) == [
             "view",
             "console.read",
             "console.write"
           ]

    assert Access.normalize_actions(["device.reboot", "superadmin"]) == ["superadmin"]
    assert Access.normalize_actions(["bogus"]) == []
  end

  test "права наследуются вниз и не действуют на соседей", %{floor: floor, room: room, core: core} do
    petrov = user("petrov")
    in_room = device_in([room])
    in_core = device_in([core])
    unfiled = approved_device()

    grant!(petrov, "engineer", floor)
    actor = actor(petrov)

    assert Fleet.can?(actor, "device.reboot", in_room)
    refute Fleet.can?(actor, "view", in_core)
    refute Fleet.can?(actor, "view", unfiled)
    refute Access.can?(actor, "enrollment.approve")

    assert {:ok, _} = Fleet.rename(actor, in_room.id, "sw-301")
    assert {:error, :forbidden} = Fleet.rename(actor, in_core.id, "sw-core")
    assert {:error, :forbidden} = Fleet.revoke(actor, in_room.id)
    assert Fleet.fetch_device(actor, in_core.id) == nil
  end

  test "обзор фильтрует устройства и показывает путь до доступной папки серым", %{
    building: building,
    floor: floor,
    room: room,
    core: core
  } do
    sidorov = user("sidorov")
    shared = device_in([room, core])
    _hidden = device_in([floor])
    pending_device()

    grant!(sidorov, "viewer", core)
    overview = Fleet.overview(actor(sidorov))

    assert overview.requests == []
    assert overview.total == 1
    assert Enum.map(overview.folders, & &1.id) == [core.id]
    core_id = core.id
    shared_id = shared.id
    assert %{^core_id => [%{id: ^shared_id, folder_ids: [^core_id]}]} = overview.devices

    ivanov = user("ivanov")
    grant!(ivanov, "viewer", room)
    overview = Fleet.overview(actor(ivanov))

    assert Enum.map(overview.folders, & &1.id) == [building.id, floor.id, room.id]
    assert overview.dim == MapSet.new([building.id, floor.id])
  end

  test "группа: права участников появляются и пропадают вместе с членством", %{building: building} do
    kozlov = user("kozlov")
    device = device_in([building])
    {:ok, group} = Access.create_group(system(), "Сетевики А")
    grant!(group, "operator", building)

    refute Fleet.can?(actor(kozlov), "console.write", device)

    :ok = Access.add_member(system(), group.id, kozlov.id)
    assert Fleet.can?(actor(kozlov), "console.write", device)
    refute Fleet.can?(actor(kozlov), "device.configure", device)

    :ok = Access.remove_member(system(), group.id, kozlov.id)
    refute Fleet.can?(actor(kozlov), "view", device)
  end

  test "консоль: ввод только с console.write", %{core: core} do
    reader = user("reader")
    device = device_in([core])
    grant!(reader, "viewer", core)

    assert {:error, :forbidden} = Bastion.Console.attach(actor(reader), device.id)
    assert {:error, :forbidden} = Bastion.Console.take(actor(reader), device.id)
    assert {:error, :forbidden} = Bastion.Control.reboot(actor(reader), device.id)
  end

  test "положить устройство в папку можно только с folder.manage на эту папку", %{
    room: room,
    core: core
  } do
    engineer = user("engineer")
    device = device_in([room])
    grant!(engineer, "engineer", room)

    assert {:error, :forbidden} =
             Fleet.set_folders(actor(engineer), device.id, [room.id, core.id])

    grant!(engineer, "viewer", core)

    assert {:error, :forbidden} =
             Fleet.set_folders(actor(engineer), device.id, [room.id, core.id])

    grant!(engineer, "engineer", core)
    assert {:ok, _} = Fleet.set_folders(actor(engineer), device.id, [room.id, core.id])
  end

  test "папки: создавать внутри можно только с folder.manage", %{floor: floor, core: core} do
    engineer = user("builder")
    grant!(engineer, "engineer", floor)

    assert {:ok, _} = Fleet.create_folder(actor(engineer), "Кабинет 302", floor.id)
    assert {:error, :forbidden} = Fleet.create_folder(actor(engineer), "Корень")
    assert {:error, :forbidden} = Fleet.rename_folder(actor(engineer), core.id, "Ядро")
  end

  test "заявки и устройства «Без папки» — только глобальные права" do
    approver = user("approver")
    pending = pending_device()

    assert {:error, :forbidden} = Fleet.approve(actor(approver), pending.id, pending.device_code)

    {:ok, role} = Access.create_role(system(), "Приёмка", ["enrollment.approve"])
    {:ok, _} = Access.grant(system(), %{user_id: approver.id, role_id: role.id})

    assert [%{id: id}] = Fleet.overview(actor(approver)).requests
    assert id == pending.id
    assert {:ok, _} = Fleet.approve(actor(approver), pending.id, pending.device_code)
  end

  test "суперадмин: последнего не лишить роли, выдать может только суперадмин", %{core: core} do
    {:ok, :created} = Accounts.ensure_admin("admin", "correct horse battery")
    admin = Enum.find(Accounts.list_users(), &(&1.username == "admin"))
    [only] = Enum.filter(Access.list_grants(), &(&1.user_id == admin.id))

    assert {:error, :last_superadmin} = Access.revoke(actor(admin), only.id)

    assert {:error, :builtin_role} =
             Access.update_role(actor(admin), role("superadmin").id, "Root", [])

    assert {:error, :builtin_role} = Access.delete_role(actor(admin), role("viewer").id)

    manager = user("manager")
    {:ok, managers} = Access.create_role(actor(admin), "Кадры", ["users.manage"])
    {:ok, _} = Access.grant(actor(admin), %{user_id: manager.id, role_id: managers.id})

    assert {:error, :forbidden} =
             Access.grant(actor(manager), %{user_id: manager.id, role_id: role("superadmin").id})

    assert {:error, :forbidden} = Accounts.block(actor(manager), admin.id)

    assert {:error, :global_role} =
             Access.grant(actor(admin), %{
               user_id: manager.id,
               role_id: managers.id,
               folder_id: core.id
             })

    assert {:error, :grant_exists} =
             Access.grant(actor(admin), %{user_id: manager.id, role_id: managers.id})
  end

  test "изменения рассылают GrantsChanged и попадают в журнал доступа", %{core: core} do
    petrov = user("petrov")
    Access.subscribe()

    grant = grant!(petrov, "viewer", core)
    assert_receive {:event, %GrantsChanged{change: :access_granted}}
    :ok = Access.revoke(system(), grant.id)
    assert_receive {:event, %GrantsChanged{change: :access_revoked}}

    :ok = Accounts.sync_journal()

    assert [
             %{type: :access_revoked, username: "petrov"},
             %{type: :access_granted, username: "petrov", data: data} | _
           ] = Accounts.list_access_events()

    assert data == %{"role" => "Наблюдатель", "folder_id" => core.id}
  end
end
