alias Bastion.Fleet

if Mix.env() != :dev do
  IO.puts("seeds: только для разработки (MIX_ENV=dev)")
  System.halt(0)
end

folder = fn name ->
  case Enum.find(Fleet.list_folders(), &(&1.name == name)) do
    nil -> elem(Fleet.create_folder(name), 1)
    existing -> existing
  end
end

device = fn device_id, name ->
  case Fleet.find_by_device_id(device_id) do
    nil ->
      csr =
        X509.PrivateKey.new_ec(:secp256r1)
        |> X509.CSR.new("/CN=#{device_id}")
        |> X509.CSR.to_pem()

      ip = "192.168.1.#{:erlang.phash2(device_id, 200) + 20}"

      {:ok, :pending} =
        Fleet.submit_request(%{
          device_id: device_id,
          name: name,
          csr_pem: csr,
          firmware_version: "0.3.0",
          ip: ip
        })

      Fleet.find_by_device_id(device_id)

    existing ->
      existing
  end
end

approve = fn d ->
  if d.status == :pending, do: elem(Fleet.approve(d.id, d.device_code), 1), else: d
end

server_room = folder.("Серверная 1")
warehouse = folder.("Склад")

for {id, name, room} <- [
      {"aabbcc000080", "core-sw-01", server_room},
      {"aabbcc000090", "edge-rt-02", server_room},
      {"aabbcc0000a0", "access-sw-07", server_room},
      {"aabbcc0000b0", "wh-sw-01", warehouse},
      {"aabbcc0000c0", "lab-esp", nil}
    ] do
  d = id |> device.(name) |> approve.()
  if room && room.id not in d.folder_ids, do: Fleet.set_folders(d.id, [room.id])
end

old = "aabbcc0000d0" |> device.("decommissioned-sw") |> approve.()
if old.status == :approved, do: Fleet.revoke(old.id)

device.("aabbcc0000e0", "esp-wcs-85e1")

IO.puts("seeds: готово — 2 папки, 7 устройств (одна заявка, одно отозванное)")
