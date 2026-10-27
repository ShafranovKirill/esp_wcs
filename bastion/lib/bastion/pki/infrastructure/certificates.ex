defmodule Bastion.PKI.Infrastructure.Certificates do
  alias Bastion.PKI.Domain.Hosts
  alias X509.Certificate.{Extension, Template}

  @p256 {1, 2, 840, 10045, 3, 1, 7}

  @ca_subject "/O=ESP WCS/CN=ESP WCS Bastion Root CA"
  @ca_days 365 * 20
  @server_days 397
  @device_days 365 * 10

  @type key :: X509.PrivateKey.t()
  @type cert :: X509.Certificate.t()

  @spec new_key() :: key()
  def new_key, do: X509.PrivateKey.new_ec(:secp256r1)

  @spec root_ca(key()) :: cert()
  def root_ca(key) do
    X509.Certificate.self_signed(key, @ca_subject,
      template: :root_ca,
      validity: @ca_days,
      serial: {:random, 16}
    )
  end

  @spec server(key(), Hosts.t(), cert(), key()) :: cert()
  def server(key, hosts, ca_cert, ca_key) do
    key
    |> X509.PublicKey.derive()
    |> X509.Certificate.new("/O=ESP WCS/CN=#{Hosts.mdns_name()}", ca_cert, ca_key,
      template: :server,
      validity: @server_days,
      serial: {:random, 16},
      extensions: [subject_alt_name: Extension.subject_alt_name(Enum.map(hosts, &san_entry/1))]
    )
  end

  @spec device(X509.PublicKey.t(), String.t(), cert(), key()) :: cert()
  def device(public_key, device_id, ca_cert, ca_key) do
    template = %Template{
      serial: {:random, 16},
      validity: @device_days,
      hash: :sha256,
      extensions: [
        basic_constraints: Extension.basic_constraints(false),
        key_usage: Extension.key_usage([:digitalSignature]),
        ext_key_usage: Extension.ext_key_usage([:clientAuth]),
        subject_key_identifier: true,
        authority_key_identifier: true
      ]
    }

    X509.Certificate.new(public_key, "/O=ESP WCS Devices/CN=#{device_id}", ca_cert, ca_key,
      template: template
    )
  end

  @spec parse_csr(String.t()) ::
          {:ok, %{public_key: X509.PublicKey.t(), common_name: String.t() | nil}}
          | {:error, :invalid_csr | :bad_signature | :unsupported_key}
  def parse_csr(pem) when is_binary(pem) do
    with {:ok, csr} <- decode_csr(pem),
         true <- X509.CSR.valid?(csr) || {:error, :bad_signature},
         public_key = X509.CSR.public_key(csr),
         true <- p256?(public_key) || {:error, :unsupported_key} do
      cn = csr |> X509.CSR.subject() |> X509.RDNSequence.get_attr(:commonName) |> List.first()
      {:ok, %{public_key: public_key, common_name: cn}}
    end
  end

  def parse_csr(_), do: {:error, :invalid_csr}

  @spec spki_der(X509.PublicKey.t()) :: binary()
  def spki_der(public_key), do: X509.PublicKey.to_der(public_key)

  @spec public_key(cert()) :: X509.PublicKey.t()
  def public_key(cert), do: X509.Certificate.public_key(cert)

  @spec hosts(cert()) :: Hosts.t()
  def hosts(cert) do
    case X509.Certificate.extension(cert, :subject_alt_name) do
      {:Extension, _, _, entries} ->
        entries
        |> Enum.flat_map(fn
          {:dNSName, name} -> [{:dns, to_string(name)}]
          {:iPAddress, ip} -> [{:ip, ip_tuple(ip)}]
          _ -> []
        end)
        |> Hosts.normalize()

      _ ->
        []
    end
  end

  @spec not_after(cert()) :: DateTime.t()
  def not_after(cert) do
    {:Validity, _from, to} = X509.Certificate.validity(cert)
    to |> :pubkey_cert.time_str_2_gregorian_sec() |> gregorian_to_datetime()
  end

  @spec issued_by?(cert(), cert()) :: boolean()
  def issued_by?(cert, ca_cert) do
    :public_key.pkix_is_issuer(X509.Certificate.to_der(cert), X509.Certificate.to_der(ca_cert)) and
      :public_key.pkix_verify(X509.Certificate.to_der(cert), X509.Certificate.public_key(ca_cert))
  end

  @spec serial_hex(cert()) :: String.t()
  def serial_hex(cert), do: cert |> X509.Certificate.serial() |> Integer.to_string(16)

  @spec to_pem(cert()) :: String.t()
  def to_pem(cert), do: X509.Certificate.to_pem(cert)

  @spec from_pem(String.t()) :: {:ok, cert()} | {:error, term()}
  def from_pem(pem), do: X509.Certificate.from_pem(pem)

  @spec from_der!(binary()) :: cert()
  def from_der!(der), do: X509.Certificate.from_der!(der)

  @spec to_der(cert()) :: binary()
  def to_der(cert), do: X509.Certificate.to_der(cert)

  @spec key_to_der(key()) :: binary()
  def key_to_der(key), do: X509.PrivateKey.to_der(key)

  @spec key_from_der(binary()) :: {:ok, key()} | {:error, term()}
  def key_from_der(der), do: X509.PrivateKey.from_der(der)

  @spec ssl_key(key()) :: {:ECPrivateKey, binary()}
  def ssl_key(key), do: {:ECPrivateKey, X509.PrivateKey.to_der(key, wrap: false)}

  defp decode_csr(pem) do
    case X509.CSR.from_pem(pem) do
      {:ok, csr} -> {:ok, csr}
      _ -> {:error, :invalid_csr}
    end
  rescue
    _ -> {:error, :invalid_csr}
  end

  defp p256?({{:ECPoint, _}, {:namedCurve, @p256}}), do: true
  defp p256?({{:ECPoint, _}, {:namedCurve, :secp256r1}}), do: true
  defp p256?(_), do: false

  defp san_entry({:dns, name}), do: name

  defp san_entry({:ip, ip}) when tuple_size(ip) == 4,
    do: {:iPAddress, ip |> Tuple.to_list() |> :binary.list_to_bin()}

  defp san_entry({:ip, ip}) when tuple_size(ip) == 8,
    do: {:iPAddress, for(word <- Tuple.to_list(ip), into: <<>>, do: <<word::16>>)}

  defp ip_tuple(ip) when is_list(ip), do: ip |> :binary.list_to_bin() |> ip_tuple()
  defp ip_tuple(<<a, b, c, d>>), do: {a, b, c, d}
  defp ip_tuple(<<_::128>> = ip), do: List.to_tuple(for <<w::16 <- ip>>, do: w)

  @gregorian_unix_epoch 62_167_219_200
  defp gregorian_to_datetime(seconds), do: DateTime.from_unix!(seconds - @gregorian_unix_epoch)
end
