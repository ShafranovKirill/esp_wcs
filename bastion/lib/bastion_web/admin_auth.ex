defmodule BastionWeb.AdminAuth do
  use BastionWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Bastion.Accounts

  @token_key "admin_token"
  @check_interval :timer.minutes(1)

  def log_in(conn, token) do
    conn
    |> renew_session()
    |> put_session(@token_key, token)
    |> put_session(:live_socket_id, live_socket_id(token))
    |> redirect(to: ~p"/")
  end

  def log_out(conn) do
    token = get_session(conn, @token_key)

    if token do
      Accounts.logout(token)
      BastionWeb.Endpoint.broadcast(live_socket_id(token), "disconnect", %{})
    end

    conn
    |> renew_session()
    |> redirect(to: ~p"/login")
  end

  def fetch_current_admin(conn, _opts) do
    admin = conn |> get_session(@token_key) |> Accounts.admin_by_session()
    assign(conn, :current_admin, admin)
  end

  def require_admin(conn, _opts) do
    if conn.assigns[:current_admin] do
      conn
    else
      conn
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  def redirect_if_admin(conn, _opts) do
    if conn.assigns[:current_admin] do
      conn
      |> redirect(to: ~p"/")
      |> halt()
    else
      conn
    end
  end

  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp live_socket_id(token), do: "admin_session:" <> Accounts.session_id(token)

  def on_mount(:require_admin, _params, session, socket) do
    token = session[@token_key]

    case Accounts.admin_by_session(token) do
      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}

      admin ->
        if Phoenix.LiveView.connected?(socket), do: schedule_check()

        socket =
          socket
          |> Phoenix.Component.assign(:current_admin, admin)
          |> Phoenix.LiveView.attach_hook(
            :admin_session_check,
            :handle_info,
            &check_session(&1, &2, token)
          )
          |> Phoenix.LiveView.attach_hook(
            :admin_session_touch,
            :handle_event,
            &touch_session(&1, &2, &3, token)
          )

        {:cont, socket}
    end
  end

  defp check_session(:check_admin_session, socket, token) do
    if Accounts.admin_by_session(token, touch: false) do
      schedule_check()
      {:halt, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}
    end
  end

  defp check_session(_message, socket, _token), do: {:cont, socket}

  defp touch_session(_event, _params, socket, token) do
    if Accounts.admin_by_session(token) do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}
    end
  end

  defp schedule_check, do: Process.send_after(self(), :check_admin_session, @check_interval)
end
