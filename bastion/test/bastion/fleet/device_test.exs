defmodule Bastion.Fleet.DeviceTest do
  use ExUnit.Case, async: true

  alias Bastion.Fleet.Device

  @t0 ~U[2026-01-01 00:00:00Z]
  @req %{
    device_id: "7c2c678c8580",
    name: "esp",
    device_code: "AAAA-BBBB-CCCC",
    csr_pem: "csr",
    firmware_version: "1",
    ip: "1.2.3.4"
  }
  @cert %{certificate_pem: "cert", serial: "AB", not_after: ~U[2036-01-01 00:00:00.123Z]}

  defp at(seconds), do: DateTime.add(@t0, seconds)

  test "новая заявка" do
    assert {:ok, %Device{status: :pending, requested_at: @t0, csr_pem: "csr"}} =
             Device.request(nil, @req, @t0)
  end

  test "повторная заявка — не чаще раза в минуту" do
    {:ok, d} = Device.request(nil, @req, @t0)
    assert {:error, :rate_limited} = Device.request(d, %{@req | device_code: "NEW"}, at(59))

    assert {:ok, %{device_code: "NEW", requested_at: requested}} =
             Device.request(d, %{@req | device_code: "NEW"}, at(60))

    assert requested == at(60)
  end

  test "одобрение: сертификат сохранён, CSR больше не нужен" do
    {:ok, d} = Device.request(nil, @req, @t0)

    assert {:ok,
            %{status: :approved, csr_pem: nil, certificate_pem: "cert", approved_at: approved}} =
             Device.approve(d, @cert, at(5))

    assert approved == at(5)
    assert {:error, :not_pending} = Device.approve(%{d | status: :revoked}, @cert, at(5))
  end

  test "одобренное с тем же ключом получает сертификат снова, с другим — отказ" do
    {:ok, d} = Device.request(nil, @req, @t0)
    {:ok, d} = Device.approve(d, @cert, at(1))
    assert {:already_approved, ^d} = Device.request(d, @req, at(2))
    assert {:error, :key_mismatch} = Device.request(d, %{@req | device_code: "OTHER"}, at(2))
  end

  test "отклонение: новое удаляется, ранее одобренное возвращается в revoked" do
    {:ok, d} = Device.request(nil, @req, @t0)
    assert :delete = Device.reject(d, at(1))

    {:ok, d} = Device.approve(d, @cert, at(1))
    {:ok, d} = Device.revoke(d, at(2))
    {:ok, d} = Device.request(d, @req, at(100))
    assert {:ok, %{status: :revoked, csr_pem: nil}} = Device.reject(d, at(101))
  end

  test "отзыв только одобренного, удаление только отозванного" do
    {:ok, d} = Device.request(nil, @req, @t0)
    assert {:error, :not_approved} = Device.revoke(d, at(1))
    assert {:error, :not_revoked} = Device.delete(d)

    {:ok, d} = Device.approve(d, @cert, at(1))
    assert {:error, :not_revoked} = Device.delete(d)
    {:ok, d} = Device.revoke(d, at(2))
    assert %{status: :revoked, certificate_pem: nil} = d
    assert :delete = Device.delete(d)
  end

  test "после отзыва новая заявка — не раньше чем через минуту" do
    {:ok, d} = Device.request(nil, @req, @t0)
    {:ok, d} = Device.approve(d, @cert, at(1))
    {:ok, d} = Device.revoke(d, at(1000))
    assert {:error, :rate_limited} = Device.request(d, @req, at(1030))
    assert {:ok, %{status: :pending}} = Device.request(d, @req, at(1060))
  end
end
