defmodule Bastion.FleetFixtures do
  use Boundary, top_level?: true, check: [in: false, out: false]

  def device_id, do: :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)

  def csr(device_id, key \\ X509.PrivateKey.new_ec(:secp256r1)),
    do: key |> X509.CSR.new("/CN=#{device_id}") |> X509.CSR.to_pem()

  def request_attrs(attrs \\ %{}) do
    id = attrs[:device_id] || device_id()

    Map.merge(
      %{
        device_id: id,
        name: "esp-wcs-#{String.slice(id, -4, 4)}",
        csr_pem: csr(id),
        firmware_version: "1.0.0",
        ip: "192.168.1.37"
      },
      attrs
    )
  end

  def pending_device(attrs \\ %{}) do
    attrs = request_attrs(attrs)
    {:ok, :pending} = Bastion.Fleet.submit_request(attrs)
    Bastion.Fleet.find_by_device_id(attrs.device_id)
  end

  def approved_device(attrs \\ %{}) do
    pending = pending_device(attrs)
    {:ok, device} = Bastion.Fleet.approve(pending.id, pending.device_code)
    device
  end
end
