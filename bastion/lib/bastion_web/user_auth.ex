defmodule BastionWeb.UserAuth do
  use BastionWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Bastion.Accounts
  alias Bastion.Accounts.Events.SessionsClosed

  @token_key "user_token"
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

  def fetch_current_user(conn, _opts) do
    user = conn |> get_session(@token_key) |> Accounts.user_by_session()
    assign(conn, :current_user, user)
  end

  def require_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end

  def redirect_if_user(conn, _opts) do
    if conn.assigns[:current_user] do
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

  defp live_socket_id(token), do: "user_session:" <> Accounts.session_id(token)

  def on_mount(:require_user, _params, session, socket) do
    token = session[@token_key]

    case Accounts.user_by_session(token) do
      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}

      user ->
        if Phoenix.LiveView.connected?(socket) do
          Accounts.subscribe(user.id)
          schedule_check()
        end

        socket =
          socket
          |> Phoenix.Component.assign(:current_user, user)
          |> Phoenix.LiveView.attach_hook(
            :user_session_check,
            :handle_info,
            &check_session(&1, &2, token)
          )
          |> Phoenix.LiveView.attach_hook(
            :user_session_touch,
            :handle_event,
            &touch_session(&1, &2, &3, token)
          )

        {:cont, socket}
    end
  end

  defp check_session(:check_user_session, socket, token) do
    if Accounts.user_by_session(token, touch: false) do
      schedule_check()
      {:halt, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}
    end
  end

  defp check_session({:event, %SessionsClosed{}}, socket, _token),
    do: {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}

  defp check_session(_message, socket, _token), do: {:cont, socket}

  defp touch_session(_event, _params, socket, token) do
    if Accounts.user_by_session(token) do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}
    end
  end

  defp schedule_check, do: Process.send_after(self(), :check_user_session, @check_interval)
end
