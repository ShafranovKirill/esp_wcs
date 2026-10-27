defmodule BastionWeb.ConnectLiveTest do
  use BastionWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :log_in_admin

  test "инструкция, адреса с портом WCS Link и код бастиона", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/connect")
    assert html =~ "bastion.local:7443"
    assert html =~ Bastion.PKI.bastion_code()
    assert html =~ ~s(id="download-ca")
  end

  test "корневой сертификат скачивается без входа", %{conn: _conn} do
    conn = get(build_conn(), ~p"/ca.crt")
    assert response(conn, 200) =~ "BEGIN CERTIFICATE"
    assert [ct] = get_resp_header(conn, "content-type")
    assert ct =~ "x509-ca-cert"
    _ = conn
  end
end
