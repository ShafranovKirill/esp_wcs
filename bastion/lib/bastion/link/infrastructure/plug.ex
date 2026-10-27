defmodule Bastion.Link.Infrastructure.Plug do
  @behaviour Plug

  import Plug.Conn

  alias Bastion.Link.Application.Session
  alias Bastion.Link.Domain.Protocol

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "GET", path_info: ["link"]} = conn, _opts) do
    peer = get_peer_data(conn)
    session = %{cert_der: peer[:ssl_cert], ip: format_ip(peer.address)}

    conn
    |> WebSockAdapter.upgrade(Session, session,
      timeout: :timer.seconds(60),
      max_frame_size: Protocol.max_frame()
    )
    |> halt()
  end

  def call(conn, _opts), do: conn |> send_resp(404, "") |> halt()

  defp format_ip({0, 0, 0, 0, 0, 0xFFFF, ab, cd}),
    do: format_ip({div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)})

  defp format_ip(ip), do: ip |> :inet.ntoa() |> to_string()
end
