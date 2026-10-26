defmodule Bastion.PKI do
  @moduledoc """
  Контекст PKI — собственный центр сертификации бастиона (`docs/bastion.md`).

  - корневой сертификат: создаётся при первом запуске, ключ на диске зашифрован
    паролем `BASTION_CA_PASSPHRASE`;
  - сертификат сервера для HTTPS (443) и WCS Link (7443), перевыпускается сам;
  - подпись запросов устройств (CSR) при одобрении;
  - коды для сверки ключей человеком.
  """
  use Boundary,
    top_level?: true,
    deps: [Bastion.Events],
    exports: [Events, Events.ServerCertificateRenewed]

  alias Bastion.PKI.Application.Authority
  alias Bastion.PKI.Domain.{Code, Hosts}
  alias Bastion.PKI.Infrastructure.Certificates

  @type device_certificate :: %{
          certificate_pem: String.t(),
          serial: String.t(),
          not_after: DateTime.t(),
          device_code: Code.t()
        }

  @doc "Процесс центра сертификации — в дерево супервизора до веб-сервера"
  defdelegate child_spec(opts), to: Authority

  @doc "Код бастиона для сверки при настройке ESP: `7F3A-91C2-B4E0`"
  @spec bastion_code() :: Code.t()
  def bastion_code, do: Authority.info().ca_code

  @doc "Корневой сертификат (PEM) — для страницы «Скачать корневой сертификат»"
  @spec root_certificate_pem() :: String.t()
  def root_certificate_pem, do: Authority.info().ca_cert_pem

  @doc """
  Опции `:ssl` для TLS-слушателя: сертификат сервера, ключ (из памяти, на диске
  открытым текстом не лежит) и корневой сертификат для цепочки.
  """
  @spec server_ssl_options() :: keyword()
  def server_ssl_options do
    info = Authority.info()
    [cert: info.server_cert_der, key: info.server_key, cacerts: [info.ca_cert_der]]
  end

  @doc "Корневой сертификат (DER) — для проверки сертификатов устройств"
  @spec root_certificate_der() :: binary()
  def root_certificate_der, do: Authority.info().ca_cert_der

  @doc "Адреса бастиона для подключения устройства: `bastion.local`, IP, домены"
  @spec device_addresses() :: [String.t()]
  def device_addresses, do: Hosts.device_addresses(Authority.info().hosts)

  @doc "Подписать CSR устройства; CN в CSR должен совпадать с `device_id`"
  @spec sign_device_csr(String.t(), String.t()) ::
          {:ok, device_certificate()}
          | {:error, :invalid_csr | :bad_signature | :unsupported_key | :subject_mismatch}
  def sign_device_csr(csr_pem, device_id), do: Authority.sign_device_csr(csr_pem, device_id)

  @doc """
  Проверить CSR из заявки, ничего не подписывая: подпись верна, ключ P-256,
  CN = `device_id`. Возвращает код устройства для сверки.
  """
  @spec check_device_csr(String.t() | nil, String.t()) ::
          {:ok, Code.t()}
          | {:error, :invalid_csr | :bad_signature | :unsupported_key | :subject_mismatch}
  def check_device_csr(csr_pem, device_id) when is_binary(csr_pem) do
    with {:ok, %{public_key: public_key, common_name: cn}} <- Certificates.parse_csr(csr_pem),
         true <- cn == device_id || {:error, :subject_mismatch} do
      {:ok, public_key |> Certificates.spki_der() |> Code.from_spki_der()}
    end
  end

  def check_device_csr(_csr_pem, _device_id), do: {:error, :invalid_csr}

  @doc "Код устройства по его CSR (без подписи) — для заявки"
  @spec device_code(String.t()) ::
          {:ok, Code.t()} | {:error, :invalid_csr | :bad_signature | :unsupported_key}
  def device_code(csr_pem) do
    with {:ok, %{public_key: public_key}} <- Certificates.parse_csr(csr_pem) do
      {:ok, public_key |> Certificates.spki_der() |> Code.from_spki_der()}
    end
  end

  @doc """
  CN и серийный номер сертификата клиента (DER) из TLS. Цепочку уже проверил
  `:ssl` (сертификат подписан нашим CA); здесь — только данные для сверки с БД.
  """
  @spec client_certificate_identity(binary()) ::
          {:ok, %{common_name: String.t(), serial: String.t()}} | {:error, :invalid_certificate}
  def client_certificate_identity(cert_der) when is_binary(cert_der) do
    cert = Certificates.from_der!(cert_der)

    case X509.Certificate.subject(cert, "CN") do
      [cn] -> {:ok, %{common_name: cn, serial: Certificates.serial_hex(cert)}}
      _ -> {:error, :invalid_certificate}
    end
  rescue
    _ -> {:error, :invalid_certificate}
  end

  @doc "Код по сертификату (DER) — например, для сертификата клиента в TLS"
  @spec certificate_code(binary()) :: Code.t()
  def certificate_code(cert_der) do
    cert_der
    |> Certificates.from_der!()
    |> Certificates.public_key()
    |> Certificates.spki_der()
    |> Code.from_spki_der()
  end
end
