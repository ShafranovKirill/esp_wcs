defmodule Bastion.FleetTest do
  use Bastion.DataCase, async: false

  import Bastion.FleetFixtures

  alias Bastion.Fleet

  alias Bastion.Fleet.Events.{
    DeviceApproved,
    DeviceChanged,
    DeviceRequested,
    DeviceRevoked,
    FoldersChanged
  }

  setup do
    Fleet.subscribe()
    :ok
  end

  describe "заявки" do
    test "новая заявка видна на главной с кодом устройства" do
      attrs = request_attrs()
      assert {:ok, :pending} = Fleet.submit_request(attrs)
      assert_receive {:event, %DeviceRequested{device_id: id}}
      assert id == attrs.device_id

      assert %{requests: [device], folders: [], unfiled: [], total: 0} = Fleet.overview(system())
      assert device.status == :pending
      assert device.device_code =~ ~r/\A[0-9A-F]{4}(-[0-9A-F]{4}){4}\z/
      assert [%{type: :requested}] = Fleet.list_events(device.id)
    end

    test "CSR с чужим CN или мусор отклоняются" do
      id = device_id()

      assert {:error, :subject_mismatch} =
               Fleet.submit_request(request_attrs(%{device_id: id, csr_pem: csr(device_id())}))

      assert {:error, :invalid_csr} = Fleet.submit_request(request_attrs(%{csr_pem: "garbage"}))

      assert {:error, :invalid_device_id} =
               Fleet.submit_request(request_attrs(%{device_id: "not-a-mac"}))
    end

    test "одобрение подписывает сертификат и сообщает о нём" do
      device = pending_device()
      assert {:ok, approved} = Fleet.approve(system(), device.id, device.device_code)
      assert approved.status == :approved
      assert approved.certificate_pem =~ "BEGIN CERTIFICATE"
      assert_receive {:event, %DeviceApproved{certificate_pem: pem}}
      assert pem == approved.certificate_pem
    end

    test "устройство, бывшее офлайн при одобрении, получает сертификат на повторную заявку" do
      key = X509.PrivateKey.new_ec(:secp256r1)
      id = device_id()
      approved = approved_device(%{device_id: id, csr_pem: csr(id, key)})

      assert {:ok, {:approved, pem}} =
               Fleet.submit_request(request_attrs(%{device_id: id, csr_pem: csr(id, key)}))

      assert pem == approved.certificate_pem
    end

    test "одобренное устройство с другим ключом — отказ" do
      id = device_id()
      approved_device(%{device_id: id})
      assert {:error, :key_mismatch} = Fleet.submit_request(request_attrs(%{device_id: id}))
    end

    test "частые заявки — отказ" do
      id = device_id()
      key = X509.PrivateKey.new_ec(:secp256r1)
      pending_device(%{device_id: id, csr_pem: csr(id, key)})

      assert {:error, :rate_limited} =
               Fleet.submit_request(request_attrs(%{device_id: id, csr_pem: csr(id, key)}))
    end

    test "заявку на рассмотрении нельзя подменить другим ключом" do
      id = device_id()
      device = pending_device(%{device_id: id})
      assert {:error, :key_mismatch} = Fleet.submit_request(request_attrs(%{device_id: id}))
      assert Fleet.get_device(device.id).device_code == device.device_code
    end

    test "одобрение только с тем кодом, который видел администратор" do
      device = pending_device()

      assert {:error, :code_changed} =
               Fleet.approve(system(), device.id, "AAAA-BBBB-CCCC-DDDD-EEEE")

      assert Fleet.get_device(device.id).status == :pending
    end

    test "заявок на рассмотрении не больше лимита" do
      for _ <- 1..Bastion.Fleet.Device.max_pending(), do: pending_device()
      assert {:error, :too_many_requests} = Fleet.submit_request(request_attrs())
    end

    test "отклонение новой заявки удаляет устройство" do
      device = pending_device()
      assert {:ok, :deleted} = Fleet.reject(system(), device.id)
      assert Fleet.get_device(device.id) == nil
      assert_receive {:event, %DeviceChanged{change: :deleted}}
    end

    test "занятое имя у новой заявки получает суффикс из ID" do
      pending_device(%{name: "core-sw"})
      id = device_id()
      device = pending_device(%{device_id: id, name: "CORE-SW"})
      assert device.name == "CORE-SW-" <> String.slice(id, -4, 4)
    end
  end

  describe "отзыв и удаление" do
    test "отзыв: событие для Link, сертификат забыт, удалить можно только после отзыва" do
      device = approved_device()
      assert {:error, :not_revoked} = Fleet.delete(system(), device.id)

      assert {:ok, revoked} = Fleet.revoke(system(), device.id)
      assert revoked.status == :revoked
      assert revoked.certificate_pem == nil
      assert_receive {:event, %DeviceRevoked{}}

      assert {:ok, :deleted} = Fleet.delete(system(), device.id)
      assert Fleet.get_device(device.id) == nil
    end

    test "несуществующее устройство" do
      assert {:error, :not_found} =
               Fleet.approve(system(), Ecto.UUID.generate(), "AAAA-BBBB-CCCC-DDDD-EEEE")

      assert {:error, :not_found} = Fleet.revoke(system(), "garbage")
    end
  end

  describe "имена и папки" do
    test "переименование: уникально без учёта регистра, пишется в журнал" do
      a = approved_device(%{name: "alpha"})
      b = approved_device(%{name: "beta"})

      assert {:error, :name_taken} = Fleet.rename(system(), b.id, "ALPHA")
      assert {:error, :blank} = Fleet.rename(system(), b.id, "   ")
      assert {:error, :too_long} = Fleet.rename(system(), b.id, String.duplicate("x", 65))
      assert {:ok, %{name: "core sw 01"}} = Fleet.rename(system(), a.id, "  core   sw 01 ")

      assert %{type: :renamed, data: %{"from" => "alpha", "to" => "core sw 01"}} =
               hd(Fleet.list_events(a.id))
    end

    test "папки: устройства группируются, непустую папку удалить нельзя" do
      device = approved_device()
      assert {:ok, folder} = Fleet.create_folder(system(), "Серверная 1")
      assert_receive {:event, %FoldersChanged{}}
      assert {:error, :name_taken} = Fleet.create_folder(system(), "серверная 1")

      assert {:ok, %{folder_ids: [fid]}} = Fleet.set_folders(system(), device.id, [folder.id])
      assert fid == folder.id
      assert %{devices: %{^fid => [%{id: id}]}, unfiled: [], total: 1} = Fleet.overview(system())
      assert id == device.id
      assert %{type: :moved, data: %{"folders" => ["Серверная 1"]}} = hd(Fleet.list_events(id))

      assert {:error, :folder_not_found} =
               Fleet.set_folders(system(), device.id, [Ecto.UUID.generate()])

      assert {:error, :folder_not_empty} = Fleet.delete_folder(system(), folder.id)

      assert {:ok, %{folder_ids: []}} = Fleet.set_folders(system(), device.id, [])
      assert :ok = Fleet.delete_folder(system(), folder.id)
      assert %{folders: [], unfiled: [%{id: ^id, folder_ids: []}]} = Fleet.overview(system())
    end

    test "переименование папки" do
      {:ok, folder} = Fleet.create_folder(system(), "Склад")
      assert {:ok, %{name: "Склад 2"}} = Fleet.rename_folder(system(), folder.id, "Склад 2")
    end
  end
end
