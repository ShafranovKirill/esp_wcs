defmodule BastionWeb.MapBackgroundController do
  use BastionWeb, :controller

  def show(conn, %{"id" => id}) do
    actor = Bastion.Access.actor(conn.assigns.current_user)

    case Bastion.Maps.read_background(actor, id) do
      {:ok, source, type} ->
        conn =
          conn
          |> put_resp_content_type(type)
          |> put_resp_header("cache-control", "private, no-store")
          |> put_resp_header("x-content-type-options", "nosniff")

        case source do
          {:file, path} -> send_file(conn, 200, path)
          {:data, data} -> send_resp(conn, 200, data)
        end

      {:error, reason}
      when reason in [:storage_unavailable, :storage_denied, :storage_not_configured] ->
        conn
        |> put_resp_header("retry-after", "5")
        |> send_resp(503, "Background storage temporarily unavailable")

      _ ->
        send_resp(conn, 404, "Not found")
    end
  end
end
