defmodule Bastion.PKI.Domain.HostsTest do
  use ExUnit.Case, async: true

  alias Bastion.PKI.Domain.Hosts

  test "собирает имя машины, mDNS, адреса и дополнительные значения без повторов" do
    hosts =
      Hosts.build("Lab", [{192, 168, 1, 10}], ["bastion.example.com", "192.168.1.10", "bad host!"])

    assert {:dns, "bastion.local"} in hosts
    assert {:dns, "lab"} in hosts
    assert {:dns, "lab.local"} in hosts
    assert {:dns, "bastion.example.com"} in hosts
    assert {:ip, {192, 168, 1, 10}} in hosts
    assert {:ip, {127, 0, 0, 1}} in hosts
    assert Enum.count(hosts, &(&1 == {:ip, {192, 168, 1, 10}})) == 1
    refute Enum.any?(hosts, &match?({:dns, "bad host!"}, &1))
  end

  test "порядок не влияет на результат — по нему решается перевыпуск" do
    assert Hosts.build("a", [{10, 0, 0, 1}, {10, 0, 0, 2}], []) ==
             Hosts.build("a", [{10, 0, 0, 2}, {10, 0, 0, 1}], [])
  end

  test "адреса для устройств: сначала bastion.local, без localhost и loopback" do
    hosts = Hosts.build("lab", [{192, 168, 1, 10}, {0xFE80, 0, 0, 0, 0, 0, 0, 1}], [])

    assert ["bastion.local" | rest] = Hosts.device_addresses(hosts)
    assert "192.168.1.10" in rest
    refute "localhost" in rest
    refute "127.0.0.1" in rest
    refute "fe80::1" in rest
  end

  test "parse_list разбирает BASTION_HOSTS" do
    assert Hosts.parse_list(" a.example , ,10.0.0.1,") == ["a.example", "10.0.0.1"]
    assert Hosts.parse_list(nil) == []
  end
end
