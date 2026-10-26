defmodule BastionWeb.SessionControllerTest do
  use BastionWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @password "correct horse battery"

  setup do
    {:ok, :created} = Bastion.Accounts.ensure_admin("admin", @password)
    :ok
  end

  defp log_in(conn, password \\ @password) do
    post(conn, ~p"/login", %{"session" => %{"username" => "admin", "password" => password}})
  end

  test "без входа главная перенаправляет на /login", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/")) == ~p"/login"
  end

  test "страница входа", %{conn: conn} do
    html = conn |> get(~p"/login") |> html_response(200)
    assert html =~ ~s(id="login-form")
  end

  test "вход и выход", %{conn: conn} do
    conn = log_in(conn)
    assert redirected_to(conn) == ~p"/"

    cookie = conn.resp_cookies["_bastion_key"]
    assert cookie.secure
    assert cookie.http_only
    assert cookie.same_site == "Strict"

    conn = get(recycle(conn), ~p"/")
    assert html_response(conn, 200) =~ "admin"

    conn = delete(recycle(conn), ~p"/logout")
    assert redirected_to(conn) == ~p"/login"
    assert redirected_to(get(recycle(conn), ~p"/")) == ~p"/login"
  end

  test "неверный пароль — 401 и сообщение", %{conn: conn} do
    conn = log_in(conn, "wrong password")
    assert html_response(conn, 401) =~ ~s(id="login-error")
  end

  test "вошедшего со страницы входа отправляет на главную", %{conn: conn} do
    conn = conn |> log_in() |> recycle() |> get(~p"/login")
    assert redirected_to(conn) == ~p"/"
  end

  test "LiveView без сессии — на вход", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/")
  end

  test "заголовок CSP запрещает inline-скрипты и чужие источники", %{conn: conn} do
    [csp] = conn |> get(~p"/login") |> get_resp_header("content-security-policy")
    assert csp =~ "script-src 'self'"
    refute csp =~ "unsafe-eval"
  end
end
