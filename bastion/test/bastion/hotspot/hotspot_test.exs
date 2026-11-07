defmodule Bastion.HotspotTest do
  use ExUnit.Case, async: false

  alias Bastion.Access.Actor

  setup do
    previous = Application.get_env(:bastion, Bastion.Hotspot)

    Application.put_env(:bastion, Bastion.Hotspot,
      enabled: true,
      ssid: "test-network",
      password: "test-password"
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bastion, Bastion.Hotspot, previous),
        else: Application.delete_env(:bastion, Bastion.Hotspot)
    end)

    :ok
  end

  test "обычный сотрудник не получает пароль и не управляет сетью" do
    actor = %Actor{global: MapSet.new(["device.wifi"])}
    assert Bastion.Hotspot.details(actor) == nil
    assert Bastion.Hotspot.change(actor, :start) == {:error, :forbidden}
    assert Bastion.Hotspot.change(actor, :stop) == {:error, :forbidden}
  end

  test "отключённый режим не запускает NetworkManager" do
    Application.put_env(:bastion, Bastion.Hotspot, enabled: false)
    actor = %Actor{global: MapSet.new(["superadmin"])}
    assert Bastion.Hotspot.details(actor) == nil
    assert Bastion.Hotspot.change(actor, :start) == {:error, :disabled}
  end

  test "суперадминистратор видит настройки подготовленной сети" do
    actor = %Actor{global: MapSet.new(["superadmin"])}

    assert %{ssid: "test-network", password: "test-password", address: "10.42.0.1:7443"} =
             Bastion.Hotspot.details(actor)
  end
end
