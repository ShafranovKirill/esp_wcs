defmodule BastionWeb.CAController do
  use BastionWeb, :controller

  @filename "esp-wcs-bastion-ca.crt"

  def show(conn, _params) do
    conn
    |> put_resp_content_type("application/x-x509-ca-cert")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{@filename}"))
    |> send_resp(200, Bastion.PKI.root_certificate_pem())
  end

  def page(conn, _params) do
    fingerprint =
      :sha256
      |> :crypto.hash(Bastion.PKI.root_certificate_der())
      |> Base.encode16()
      |> String.graphemes()
      |> Enum.chunk_every(2)
      |> Enum.map_join(":", &Enum.join/1)

    render(conn, :page,
      page_title: gettext("Root certificate"),
      filename: @filename,
      fingerprint: fingerprint,
      bastion_code: Bastion.PKI.bastion_code()
    )
  end
end
