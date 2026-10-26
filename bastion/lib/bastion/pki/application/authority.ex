defmodule Bastion.PKI.Application.Authority do
  @moduledoc """
  Центр сертификации бастиона: процесс, который держит в памяти ключ корневого
  сертификата и выпускает сертификаты.

  При запуске (синхронно, до веб-сервера):
  - корневой сертификат загружается или, если его нет совсем, создаётся;
  - сертификат сервера перевыпускается, если его нет, он подписан другим CA,
    истекает в ближайшие 30 дней или изменились адреса машины.

  Раз в сутки проверка сертификата сервера повторяется; о перевыпуске
  сообщает событие `Bastion.PKI.Events.ServerCertificateRenewed`.
  """
  use GenServer
  require Logger

  alias Bastion.PKI.Domain.{Code, Hosts}
  alias Bastion.PKI.Events.ServerCertificateRenewed
  alias Bastion.PKI.Infrastructure.{Certificates, FileStore, HostDiscovery, KeyVault}

  @ca_key "ca.key.enc"
  @ca_cert "ca.crt"
  @server_key "server.key.enc"
  @server_cert "server.crt"

  @renew_before_days 30
  @check_interval :timer.hours(24)

  defstruct [:config, :ca_cert, :ca_key, :ca_code, :server_cert, :server_key, :hosts]

  # ---- API ----

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  def sign_device_csr(server \\ __MODULE__, csr_pem, device_id),
    do: GenServer.call(server, {:sign_device_csr, csr_pem, device_id})

  def check_server_certificate(server \\ __MODULE__),
    do: GenServer.call(server, :check_server_certificate)

  # ---- GenServer ----

  @impl true
  def init(opts) do
    config = config(opts)

    with {:ok, state} <- load_or_create_ca(%__MODULE__{config: config}),
         {:ok, state, _renewed?} <- ensure_server_certificate(state) do
      schedule_check()
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = %{
      ca_code: state.ca_code,
      ca_cert_pem: Certificates.to_pem(state.ca_cert),
      ca_cert_der: Certificates.to_der(state.ca_cert),
      server_cert_der: Certificates.to_der(state.server_cert),
      server_key: Certificates.ssl_key(state.server_key),
      server_not_after: Certificates.not_after(state.server_cert),
      hosts: state.hosts
    }

    {:reply, info, state}
  end

  def handle_call({:sign_device_csr, csr_pem, device_id}, _from, state) do
    {:reply, sign(csr_pem, device_id, state), state}
  end

  def handle_call(:check_server_certificate, _from, state) do
    case ensure_server_certificate(state) do
      {:ok, state, renewed?} -> {:reply, {:ok, renewed?}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:check, state) do
    schedule_check()

    case ensure_server_certificate(state) do
      {:ok, state, _} ->
        {:noreply, state}

      {:error, reason} ->
        Logger.error("server certificate check failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # ---- корневой сертификат ----

  defp load_or_create_ca(%{config: config} = state) do
    dir = config.data_dir

    case {FileStore.read(dir, @ca_key), FileStore.read(dir, @ca_cert)} do
      {{:ok, sealed}, {:ok, pem}} ->
        with {:ok, der} <- unseal(sealed, config.passphrase),
             {:ok, key} <- Certificates.key_from_der(der),
             {:ok, cert} <- Certificates.from_pem(pem) do
          Logger.info("root CA loaded, code #{ca_code(cert)}")
          {:ok, put_ca(state, cert, key)}
        end

      {{:error, :enoent}, {:error, :enoent}} ->
        create_ca(state)

      _ ->
        # Есть только ключ или только сертификат — не перезаписываем: это потеря CA
        {:error, {:ca_incomplete, dir}}
    end
  end

  defp create_ca(%{config: config} = state) do
    key = Certificates.new_key()
    cert = Certificates.root_ca(key)

    sealed =
      KeyVault.encrypt(Certificates.key_to_der(key), config.passphrase, config.kdf_iterations)

    FileStore.write!(config.data_dir, @ca_key, sealed, :secret)
    FileStore.write!(config.data_dir, @ca_cert, Certificates.to_pem(cert), :public)
    Logger.info("root CA created, code #{ca_code(cert)}")
    {:ok, put_ca(state, cert, key)}
  end

  defp put_ca(state, cert, key), do: %{state | ca_cert: cert, ca_key: key, ca_code: ca_code(cert)}

  defp ca_code(cert),
    do: cert |> Certificates.public_key() |> Certificates.spki_der() |> Code.from_spki_der()

  # ---- сертификат сервера ----

  defp ensure_server_certificate(%{config: config} = state) do
    hosts = current_hosts(config)

    case load_server(state) do
      {:ok, key, cert} ->
        case renewal_reason(cert, hosts, state.ca_cert) do
          nil ->
            {:ok, %{state | server_key: key, server_cert: cert, hosts: Certificates.hosts(cert)},
             false}

          reason ->
            issue_server(state, key, hosts, reason)
        end

      :missing ->
        issue_server(state, Certificates.new_key(), hosts, :missing)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_server(%{config: config}) do
    dir = config.data_dir

    case {FileStore.read(dir, @server_key), FileStore.read(dir, @server_cert)} do
      {{:ok, sealed}, {:ok, pem}} ->
        with {:ok, der} <- unseal(sealed, config.passphrase),
             {:ok, key} <- Certificates.key_from_der(der),
             {:ok, cert} <- Certificates.from_pem(pem) do
          {:ok, key, cert}
        end

      _ ->
        :missing
    end
  end

  defp renewal_reason(cert, hosts, ca_cert) do
    renew_at = DateTime.add(DateTime.utc_now(), @renew_before_days, :day)

    cond do
      not Certificates.issued_by?(cert, ca_cert) -> :other_ca
      DateTime.compare(Certificates.not_after(cert), renew_at) == :lt -> :expiring
      Certificates.hosts(cert) != hosts -> :hosts_changed
      true -> nil
    end
  end

  defp issue_server(%{config: config} = state, key, hosts, reason) do
    cert = Certificates.server(key, hosts, state.ca_cert, state.ca_key)

    sealed =
      KeyVault.encrypt(Certificates.key_to_der(key), config.passphrase, config.kdf_iterations)

    FileStore.write!(config.data_dir, @server_key, sealed, :secret)
    FileStore.write!(config.data_dir, @server_cert, Certificates.to_pem(cert), :public)

    Logger.info(
      "server certificate issued (#{reason}): #{hosts |> Enum.map(&Hosts.format/1) |> Enum.join(", ")}"
    )

    if reason != :missing do
      Bastion.Events.publish(:pki, %ServerCertificateRenewed{reason: reason})
    end

    {:ok, %{state | server_key: key, server_cert: cert, hosts: hosts}, true}
  end

  defp current_hosts(config) do
    Hosts.build(config.discovery.hostname(), config.discovery.addresses(), config.extra_hosts)
  end

  # ---- сертификаты устройств ----

  defp sign(csr_pem, device_id, state) do
    with {:ok, %{public_key: public_key, common_name: cn}} <- Certificates.parse_csr(csr_pem),
         true <- cn == device_id || {:error, :subject_mismatch} do
      cert = Certificates.device(public_key, device_id, state.ca_cert, state.ca_key)

      {:ok,
       %{
         certificate_pem: Certificates.to_pem(cert),
         serial: Certificates.serial_hex(cert),
         not_after: Certificates.not_after(cert),
         device_code: public_key |> Certificates.spki_der() |> Code.from_spki_der()
       }}
    end
  end

  # ---- общее ----

  defp unseal(sealed, passphrase) do
    case KeyVault.decrypt(sealed, passphrase) do
      {:ok, der} -> {:ok, der}
      {:error, :bad_passphrase} -> {:error, :bad_ca_passphrase}
      {:error, reason} -> {:error, reason}
    end
  end

  defp config(opts) do
    app = Application.get_env(:bastion, Bastion.PKI, [])
    get = fn key, default -> Keyword.get(opts, key, Keyword.get(app, key, default)) end

    passphrase = get.(:ca_passphrase, nil)

    if passphrase in [nil, ""] do
      raise ArgumentError, "BASTION_CA_PASSPHRASE is not set"
    end

    %{
      data_dir: get.(:data_dir, "data"),
      passphrase: passphrase,
      extra_hosts: get.(:extra_hosts, []),
      kdf_iterations: get.(:kdf_iterations, KeyVault.default_iterations()),
      discovery: get.(:discovery, HostDiscovery)
    }
  end

  defp schedule_check, do: Process.send_after(self(), :check, @check_interval)
end
