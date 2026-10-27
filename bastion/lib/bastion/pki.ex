defmodule Bastion.PKI do
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

  defdelegate child_spec(opts), to: Authority

  @spec bastion_code() :: Code.t()
  def bastion_code, do: Authority.info().ca_code

  @spec root_certificate_pem() :: String.t()
  def root_certificate_pem, do: Authority.info().ca_cert_pem

  @spec server_ssl_options() :: keyword()
  def server_ssl_options do
    info = Authority.info()
    [cert: info.server_cert_der, key: info.server_key, cacerts: [info.ca_cert_der]]
  end

  @spec root_certificate_der() :: binary()
  def root_certificate_der, do: Authority.info().ca_cert_der

  @spec device_addresses() :: [String.t()]
  def device_addresses, do: Hosts.device_addresses(Authority.info().hosts)

  @spec sign_device_csr(String.t(), String.t()) ::
          {:ok, device_certificate()}
          | {:error, :invalid_csr | :bad_signature | :unsupported_key | :subject_mismatch}
  def sign_device_csr(csr_pem, device_id), do: Authority.sign_device_csr(csr_pem, device_id)

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

  @spec device_code(String.t()) ::
          {:ok, Code.t()} | {:error, :invalid_csr | :bad_signature | :unsupported_key}
  def device_code(csr_pem) do
    with {:ok, %{public_key: public_key}} <- Certificates.parse_csr(csr_pem) do
      {:ok, public_key |> Certificates.spki_der() |> Code.from_spki_der()}
    end
  end

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

  @spec certificate_code(binary()) :: Code.t()
  def certificate_code(cert_der) do
    cert_der
    |> Certificates.from_der!()
    |> Certificates.public_key()
    |> Certificates.spki_der()
    |> Code.from_spki_der()
  end
end
