defmodule BastionWeb.ConnectLiveTest do
  use BastionWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :log_in_user

  test "инструкция, адреса с портом WCS Link и код бастиона", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/connect")
    assert html =~ "bastion.local:7443"
    assert html =~ Bastion.PKI.bastion_code()
    assert html =~ ~s(id="download-ca")
  end

  test "подключение только через интерфейс ESP, без hotspot", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/connect")
    assert has_element?(view, "#steps")
    assert has_element?(view, "#connection-troubleshooting")
    refute has_element?(view, "#laptop-hotspot")
    refute has_element?(view, "#hotspot-start")
  end

  test "корневой сертификат скачивается без входа", %{conn: _conn} do
    conn = get(build_conn(), ~p"/ca.crt")
    assert response(conn, 200) =~ "BEGIN CERTIFICATE"

    html = build_conn() |> get(~p"/ca") |> html_response(200)
    assert html =~ ~s(id="ca-windows")
    assert html =~ ~s(id="ca-linux")
    assert html =~ Bastion.PKI.bastion_code()

    fingerprint =
      :crypto.hash(:sha256, Bastion.PKI.root_certificate_der())
      |> Base.encode16()
      |> String.slice(0, 2)

    assert html =~ ~s(id="ca-fingerprint">#{fingerprint}:)
    assert [ct] = get_resp_header(conn, "content-type")
    assert ct =~ "x509-ca-cert"
    _ = conn
  end
end
