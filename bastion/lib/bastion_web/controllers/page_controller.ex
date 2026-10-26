defmodule BastionWeb.PageController do
  use BastionWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
