defmodule BastionWeb.UsersLiveTest do
  use BastionWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bastion.Accounts

  setup :log_in_user

  defp admin, do: Enum.find(Accounts.list_users(), &(&1.username == "admin"))

  test "создание сотрудника показывает пароль один раз", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users")

    view |> form("#user-form", user: %{username: "ivanov"}) |> render_submit()

    html = render(view)
    assert html =~ ~s(id="issued-password")
    assert has_element?(view, "#users li", "ivanov")

    view |> element("#password-seen") |> render_click()
    refute has_element?(view, "#issued-password")
  end

  test "занятый логин — ошибка в форме", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users")
    html = view |> form("#user-form", user: %{username: "ADMIN"}) |> render_submit()
    assert html =~ "уже занят"
  end

  test "блокировка выкидывает открытую страницу сотрудника", %{conn: conn} do
    {:ok, user, password} = Accounts.create_user(admin(), "petrov")
    {:ok, token} = Accounts.login("petrov", password, "127.0.0.2")

    other =
      build_conn() |> init_test_session(%{}) |> put_session("user_token", token)

    {:ok, other_view, _} = live(other, ~p"/")

    {:ok, view, _html} = live(conn, ~p"/users")
    view |> element("#block-#{user.id}") |> render_click()

    assert_redirect(other_view, ~p"/login")
    assert has_element?(view, "#user-#{user.id}", "Заблокирован")
    refute has_element?(view, "#block-#{admin().id}")
  end

  test "сброс пароля показывает новый пароль", %{conn: conn} do
    {:ok, user, _} = Accounts.create_user(admin(), "sidorov")
    {:ok, view, _html} = live(conn, ~p"/users")

    view |> element("#reset-#{user.id}") |> render_click()
    assert has_element?(view, "#issued-password")
  end

  test "журнал доступа", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/users/journal")
    assert has_element?(view, "#access-journal", "admin вошёл(ла)")
  end

  test "смена своего пароля", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/account")

    html =
      view
      |> form("#password-form",
        password: %{current: "wrong", new: "new long password", confirm: "new long password"}
      )
      |> render_submit()

    assert html =~ "Неверный текущий пароль"

    html =
      view
      |> form("#password-form",
        password: %{current: "correct horse battery", new: "new long password", confirm: "other"}
      )
      |> render_submit()

    assert html =~ "не совпадают"

    view
    |> form("#password-form",
      password: %{
        current: "correct horse battery",
        new: "new long password",
        confirm: "new long password"
      }
    )
    |> render_submit()

    assert render(view) =~ "Пароль изменён"
    assert {:ok, _} = Accounts.login("admin", "new long password", "127.0.0.3")
  end
end
