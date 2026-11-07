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

  test "управление точкой доступно только при включённом локальном режиме", %{conn: conn} do
    previous = Application.get_env(:bastion, Bastion.Hotspot)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bastion, Bastion.Hotspot, previous),
        else: Application.delete_env(:bastion, Bastion.Hotspot)
    end)

    Application.put_env(:bastion, Bastion.Hotspot, enabled: false)
    {:ok, view, _} = live(conn, ~p"/connect")
    refute has_element?(view, "#laptop-hotspot")

    Application.put_env(:bastion, Bastion.Hotspot,
      enabled: true,
      ssid: "test-network",
      password: "test-password"
    )

    {:ok, view, _} = live(conn, ~p"/connect")
    assert has_element?(view, "#hotspot-start")
    assert has_element?(view, "#hotspot-stop")
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
