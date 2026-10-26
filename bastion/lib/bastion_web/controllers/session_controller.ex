defmodule BastionWeb.SessionController do
  use BastionWeb, :controller

  alias Bastion.Accounts
  alias BastionWeb.AdminAuth

  def new(conn, _params) do
    render(conn, :new,
      form: Phoenix.Component.to_form(%{"username" => ""}, as: :session),
      error: nil
    )
  end

  def create(conn, %{"session" => %{"username" => username, "password" => password}})
      when is_binary(username) and is_binary(password) do
    case Accounts.login(username, password, remote_ip(conn)) do
      {:ok, token} ->
        AdminAuth.log_in(conn, token)

      {:error, reason} ->
        conn
        |> put_status(:unauthorized)
        |> render(:new,
          form: Phoenix.Component.to_form(%{"username" => username}, as: :session),
          error: error_text(reason)
        )
    end
  end

  def create(conn, _params), do: new(conn, %{})

  def delete(conn, _params), do: AdminAuth.log_out(conn)

  defp error_text(:invalid_credentials), do: gettext("Invalid username or password")

  defp error_text({:locked, seconds}),
    do: gettext("Too many attempts. Try again in %{seconds} s", seconds: seconds)

  defp remote_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
