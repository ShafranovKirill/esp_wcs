defmodule BastionWeb.CAController do
  use BastionWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_content_type("application/x-x509-ca-cert")
    |> put_resp_header("content-disposition", ~s(attachment; filename="esp-wcs-bastion-ca.crt"))
    |> send_resp(200, Bastion.PKI.root_certificate_pem())
  end
end
