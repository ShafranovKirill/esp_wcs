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

  def log_in_admin(%{conn: conn}) do
    {:ok, _} = Bastion.Accounts.ensure_admin("admin", "correct horse battery")
    {:ok, token} = Bastion.Accounts.login("admin", "correct horse battery", "127.0.0.1")

    %{
      conn:
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session("admin_token", token)
    }
  end

  setup tags do
    Bastion.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
