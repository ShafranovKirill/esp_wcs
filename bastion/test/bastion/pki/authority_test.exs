defmodule Bastion.PKI.Application.AuthorityTest do
  use ExUnit.Case, async: false

  alias Bastion.PKI.Application.Authority
  alias Bastion.PKI.Domain.Code
  alias Bastion.PKI.Events.ServerCertificateRenewed
  alias Bastion.PKI.FakeHostDiscovery

  @device_id "7c2c678c8580"

  setup do
    dir = Path.join(System.tmp_dir!(), "bastion-pki-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    FakeHostDiscovery.set("lab", [{192, 168, 1, 10}])
    %{dir: dir}
  end

  defp start(dir, opts \\ []) do
    opts =
      Keyword.merge(
        [
          name: :"authority_#{System.unique_integer([:positive])}",
          data_dir: dir,
          ca_passphrase: "pass",
          kdf_iterations: 1_000,
          discovery: FakeHostDiscovery
        ],
        opts
      )

    pid = start_supervised!({Authority, opts}, id: opts[:name])
    {pid, opts[:name]}
  end

  defp csr(cn, key \\ X509.PrivateKey.new_ec(:secp256r1)),
    do: X509.CSR.new(key, "/CN=#{cn}") |> X509.CSR.to_pem()

  test "первый запуск создаёт CA и сертификат сервера, ключи на диске зашифрованы", %{dir: dir} do
    {_, name} = start(dir)
    info = Authority.info(name)

    assert Code.valid?(info.ca_code)
    assert File.exists?(Path.join(dir, "ca.crt"))
    assert File.stat!(Path.join(dir, "ca.key.enc")).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(dir).mode |> Bitwise.band(0o777) == 0o700
    refute File.read!(Path.join(dir, "ca.key.enc")) =~ "PRIVATE KEY"
    assert {:ip, {192, 168, 1, 10}} in info.hosts
  end

  test "повторный запуск загружает тот же CA и не перевыпускает сертификат сервера", %{dir: dir} do
    {pid, name} = start(dir)
    first = Authority.info(name)
    stop_supervised!(name)
    refute Process.alive?(pid)

    {_, name} = start(dir)
    second = Authority.info(name)
    assert second.ca_code == first.ca_code
    assert second.server_cert_der == first.server_cert_der
  end

  test "неверный пароль CA — запуск отказывается, файлы не трогаются", %{dir: dir} do
    {_, name} = start(dir)
    stop_supervised!(name)
    before = File.read!(Path.join(dir, "ca.key.enc"))

    opts = [
      name: :bad,
      data_dir: dir,
      ca_passphrase: "wrong",
      kdf_iterations: 1_000,
      discovery: FakeHostDiscovery
    ]

    assert {:error, {:bad_ca_passphrase, _child}} = start_supervised({Authority, opts})

    assert File.read!(Path.join(dir, "ca.key.enc")) == before
  end

  test "есть только ключ CA без сертификата — не перезаписываем", %{dir: dir} do
    {_, name} = start(dir)
    stop_supervised!(name)
    File.rm!(Path.join(dir, "ca.crt"))

    assert {:error, _} =
             start_supervised(
               {Authority,
                name: :incomplete,
                data_dir: dir,
                ca_passphrase: "pass",
                kdf_iterations: 1_000,
                discovery: FakeHostDiscovery}
             )

    assert File.exists?(Path.join(dir, "ca.key.enc"))
  end

  test "смена адресов машины — сертификат сервера перевыпускается с событием", %{dir: dir} do
    {_, name} = start(dir)
    old = Authority.info(name)
    Bastion.Events.subscribe(:pki)

    FakeHostDiscovery.set("lab", [{10, 0, 0, 5}])
    assert {:ok, true} = Authority.check_server_certificate(name)
    assert_receive {:event, %ServerCertificateRenewed{reason: :hosts_changed}}

    new = Authority.info(name)
    assert {:ip, {10, 0, 0, 5}} in new.hosts
    refute {:ip, {192, 168, 1, 10}} in new.hosts
    assert new.server_cert_der != old.server_cert_der
    assert new.ca_code == old.ca_code
  end

  test "подписывает CSR устройства: CN = ID, сертификат клиента от нашего CA", %{dir: dir} do
    {_, name} = start(dir)
    key = X509.PrivateKey.new_ec(:secp256r1)

    assert {:ok, signed} = Authority.sign_device_csr(name, csr(@device_id, key), @device_id)

    cert = X509.Certificate.from_pem!(signed.certificate_pem)
    ca = X509.Certificate.from_der!(Authority.info(name).ca_cert_der)
    assert :public_key.pkix_verify(X509.Certificate.to_der(cert), X509.Certificate.public_key(ca))
    assert X509.Certificate.subject(cert, "CN") == [@device_id]

    expected = key |> X509.PublicKey.derive() |> X509.PublicKey.to_der() |> Code.from_spki_der()
    assert signed.device_code == expected
    assert DateTime.diff(signed.not_after, DateTime.utc_now(), :day) > 3600
  end

  test "отклоняет чужой CN, неверную подпись и не P-256", %{dir: dir} do
    {_, name} = start(dir)

    assert {:error, :subject_mismatch} =
             Authority.sign_device_csr(name, csr("aaaaaaaaaaaa"), @device_id)

    assert {:error, :invalid_csr} = Authority.sign_device_csr(name, "not a csr", @device_id)

    rsa_csr =
      X509.PrivateKey.new_rsa(2048) |> X509.CSR.new("/CN=#{@device_id}") |> X509.CSR.to_pem()

    assert {:error, :unsupported_key} = Authority.sign_device_csr(name, rsa_csr, @device_id)

    p384_csr =
      X509.PrivateKey.new_ec(:secp384r1) |> X509.CSR.new("/CN=#{@device_id}") |> X509.CSR.to_pem()

    assert {:error, :unsupported_key} = Authority.sign_device_csr(name, p384_csr, @device_id)
  end
end
