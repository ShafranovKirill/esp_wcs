defmodule BastionWeb.AccessLiveTest do
  use BastionWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bastion.FleetFixtures

  alias Bastion.{Access, Fleet}

  defp role(builtin), do: Enum.find(Access.list_roles(), &(&1.builtin == builtin))

  describe "администратор" do
    setup :log_in_user

    test "группа, участник и выдача на папку", %{conn: conn} do
      {:ok, folder} = Fleet.create_folder(system(), "Здание А")
      {:ok, petrov, _} = Bastion.Accounts.create_user(system(), "petrov")

      {:ok, view, _} = live(conn, ~p"/access/groups")
      view |> form("#group-form", group: %{name: "Сетевики А"}) |> render_submit()
      [group] = Access.list_groups()
      assert has_element?(view, "#group-#{group.id}", "Сетевики А")

      view
      |> form("#add-member-#{group.id}")
      |> render_change(%{group_id: group.id, user_id: petrov.id})

      assert has_element?(view, "#member-#{group.id}-#{petrov.id}")

      {:ok, view, _} = live(conn, ~p"/access")

      view
      |> form("#grant-form",
        grant: %{who: "group:#{group.id}", role_id: role("operator").id, folder_id: folder.id}
      )
      |> render_submit()

      [grant] = Enum.filter(Access.list_grants(), &(&1.group_id == group.id))
      assert has_element?(view, "#grant-#{grant.id}", "Здание А")

      view |> element("#revoke-grant-#{grant.id}") |> render_click()
      refute has_element?(view, "#grant-#{grant.id}")
    end

    test "новая роль: зависимые действия добавляются сами", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/access/roles")

      view
      |> form("#role-form", role: %{name: "Дежурный", actions: ["", "console.write"]})
      |> render_submit()

      role = Enum.find(Access.list_roles(), &(&1.name == "Дежурный"))
      assert role.actions == ["view", "console.read", "console.write"]
      assert has_element?(view, "#role-#{role.id}")
      refute has_element?(view, "#edit-role-#{role("superadmin").id}")
    end
  end

  describe "сотрудник без прав" do
    test "раздела «Доступ» и «Сотрудники» нет, устройств не видно", %{conn: conn} do
      {:ok, _} = Bastion.Accounts.ensure_admin("admin", "correct horse battery")
      device = approved_device(%{name: "core-sw-01"})
      {conn, _user} = log_in_employee(conn, "guest")

      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/access")
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/users")
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/devices/#{device.id}")

      {:ok, _view, html} = live(conn, ~p"/")
      refute html =~ "core-sw-01"
      refute html =~ ~s(href="/access")
      refute html =~ ~s(id="how-to-connect")
    end

    test "отзыв права ввода освобождает консоль, отзыв просмотра закрывает страницу", %{
      conn: conn
    } do
      {:ok, _} = Bastion.Accounts.ensure_admin("admin", "correct horse battery")
      {:ok, folder} = Fleet.create_folder(system(), "Ядро сети")
      device = approved_device()
      {:ok, _} = Fleet.set_folders(system(), device.id, [folder.id])
      {conn, user} = log_in_employee(conn, "duty")

      {:ok, viewer} =
        Access.grant(system(), %{
          user_id: user.id,
          role_id: role("viewer").id,
          folder_id: folder.id
        })

      {:ok, operator} =
        Access.grant(system(), %{
          user_id: user.id,
          role_id: role("operator").id,
          folder_id: folder.id
        })

      {:ok, view, _} = live(conn, ~p"/devices/#{device.id}")
      assert_push_event(view, "console-state", %{owner: true})
      refute has_element?(view, "#tab-settings")

      :ok = Access.revoke(system(), operator.id)
      assert_push_event(view, "console-state", %{owner: false})
      assert has_element?(view, "#console-forbidden")
      assert Bastion.Console.lock(device.id) == :free

      :ok = Access.revoke(system(), viewer.id)
      assert_redirect(view, ~p"/")
    end
  end
end
