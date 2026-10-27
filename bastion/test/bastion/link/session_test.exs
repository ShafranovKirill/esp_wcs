defmodule Bastion.Link.SessionTest do
  use Bastion.DataCase, async: false

  import Bastion.FleetFixtures

  alias Bastion.Fleet
  alias Bastion.Link.Application.Session

  @ip "192.168.1.37"

  defp text(json), do: {JSON.encode!(json), opcode: :text}

  defp push!({:push, {:text, frame}, state}), do: {JSON.decode!(frame), state}

  defp hello(id), do: text(%{t: "hello", v: 1, device_id: id, fw: "1.0", caps: ["console"]})

  defp cert_der(device),
    do: device.certificate_pem |> X509.Certificate.from_pem!() |> X509.Certificate.to_der()

  describe "регистрация" do
    test "hello → welcome enroll → заявка pending → одобрение отдаёт сертификат" do
      id = device_id()
      key = X509.PrivateKey.new_ec(:secp256r1)
      {:ok, state} = Session.init(%{ip: @ip})

      {%{"t" => "welcome", "session" => "enroll", "hb" => 15}, state} =
        push!(Session.handle_in(hello(id), state))

      {%{"status" => "pending"}, state} =
        push!(
          Session.handle_in(text(%{t: "enroll", name: "esp-wcs-8581", csr: csr(id, key)}), state)
        )

      device = Fleet.find_by_device_id(id)
      assert device.status == :pending
      assert device.last_ip == @ip

      {:ok, approved} = Fleet.approve(device.id)
      assert_receive {:event, %Fleet.Events.DeviceApproved{} = event}

      {%{"status" => "approved", "cert" => cert}, _} =
        push!(Session.handle_info({:event, event}, state))

      assert cert == approved.certificate_pem
    end

    test "отклонение — rejected" do
      id = device_id()
      {:ok, state} = Session.init(%{ip: @ip})
      {_, state} = push!(Session.handle_in(hello(id), state))
      {_, state} = push!(Session.handle_in(text(%{t: "enroll", name: "x", csr: csr(id)}), state))

      {:ok, :deleted} = Fleet.reject(Fleet.find_by_device_id(id).id)
      assert_receive {:event, %Fleet.Events.DeviceChanged{change: :deleted} = event}
      assert {%{"status" => "rejected"}, _} = push!(Session.handle_info({:event, event}, state))
    end

    test "чужой CN в CSR — закрытие 4000, частая заявка — 4008" do
      {:ok, state} = Session.init(%{ip: @ip})
      {_, state} = push!(Session.handle_in(hello(device_id()), state))

      assert {:stop, :normal, {4000, _}, _} =
               Session.handle_in(text(%{t: "enroll", name: "x", csr: csr(device_id())}), state)

      id = device_id()
      pending_device(%{device_id: id})
      {:ok, state} = Session.init(%{ip: @ip})
      {_, state} = push!(Session.handle_in(hello(id), state))

      assert {:stop, :normal, {4008, _}, _} =
               Session.handle_in(text(%{t: "enroll", name: "x", csr: csr(id)}), state)
    end

    test "heartbeat до сеанса устройства и бинарные кадры при регистрации запрещены" do
      {:ok, state} = Session.init(%{ip: @ip})
      {_, state} = push!(Session.handle_in(hello(device_id()), state))

      assert {:stop, :normal, {4000, _}, _} =
               Session.handle_in(text(%{t: "hb", seq: 1, ts: 1}), state)

      assert {:stop, :normal, {4000, _}, _} =
               Session.handle_in({<<1, 2>>, opcode: :binary}, state)
    end

    test "неподдерживаемая версия — 4001, нет hello — 4004" do
      {:ok, state} = Session.init(%{ip: @ip})

      assert {:stop, :normal, {4001, _}, _} =
               Session.handle_in(text(%{t: "hello", v: 2, device_id: device_id()}), state)

      assert {:stop, :normal, {4004, _}, _} = Session.handle_info(:hello_timeout, state)
    end
  end

  describe "сеанс устройства (mTLS)" do
    test "одобренное устройство: welcome device, онлайн, heartbeat с ответом" do
      device = approved_device()
      Bastion.Link.subscribe()
      {:ok, state} = Session.init(%{ip: @ip, cert_der: cert_der(device)})

      {%{"t" => "welcome", "session" => "device"}, state} =
        push!(Session.handle_in(hello(device.device_id), state))

      assert_receive {:event, %Bastion.Link.Events.PresenceChanged{online: true}}
      assert %{ip: @ip} = Bastion.Link.presence(device.id)

      {%{"t" => "hb_ack", "seq" => 7, "ts" => 123, "time" => time}, _} =
        push!(
          Session.handle_in(
            text(%{t: "hb", seq: 7, ts: 123, rtt: 20, rssi: -60, uptime: 99, heap: 1}),
            state
          )
        )

      assert abs(time - System.os_time(:millisecond)) < 5_000
      assert %{rtt: 20, rssi: -60, uptime: 99} = Bastion.Link.presence(device.id)
      assert Enum.any?(Fleet.list_events(device.id), &(&1.type == :connected))
    end

    test "device_id в hello не совпадает с сертификатом — 4003" do
      device = approved_device()
      {:ok, state} = Session.init(%{ip: @ip, cert_der: cert_der(device)})
      assert {:stop, :normal, {4003, _}, _} = Session.handle_in(hello(device_id()), state)
    end

    test "сертификат отозванного устройства не принимается" do
      device = approved_device()
      der = cert_der(device)
      {:ok, _} = Fleet.revoke(device.id)
      assert {:stop, :normal, {4003, _}, _} = Session.init(%{ip: @ip, cert_der: der})
    end

    test "отзыв во время сеанса закрывает соединение 4003" do
      device = approved_device()
      {:ok, state} = Session.init(%{ip: @ip, cert_der: cert_der(device)})
      {_, state} = push!(Session.handle_in(hello(device.device_id), state))

      {:ok, _} = Fleet.revoke(device.id)
      assert_receive {:event, %Fleet.Events.DeviceRevoked{} = event}
      assert {:stop, :normal, {4003, _}, _} = Session.handle_info({:event, event}, state)
    end

    test "нет heartbeat — 4005" do
      device = approved_device()
      {:ok, state} = Session.init(%{ip: @ip, cert_der: cert_der(device)})
      {_, state} = push!(Session.handle_in(hello(device.device_id), state))
      assert {:stop, :normal, {4005, _}, _} = Session.handle_info(:hb_timeout, state)
    end
  end
end
