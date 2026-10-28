defmodule BastionWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint BastionWeb.Endpoint

      use BastionWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import BastionWeb.ConnCase
    end
  end

  def log_in_user(%{conn: conn}) do
    {:ok, _} = Bastion.Accounts.ensure_admin("admin", "correct horse battery")
    {:ok, token} = Bastion.Accounts.login("admin", "correct horse battery", "127.0.0.1")

    %{
      conn:
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session("user_token", token)
    }
  end

  def log_in_employee(conn, username) do
    {:ok, user, password} = Bastion.Accounts.create_user(system(), username)
    {:ok, token} = Bastion.Accounts.login(username, password, "127.0.0.3")

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session("user_token", token)

    {conn, user}
  end

  def system, do: Bastion.Access.system()

  setup tags do
    Bastion.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
