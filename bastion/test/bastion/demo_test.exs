defmodule Bastion.DemoTest do
  use Bastion.DataCase, async: false

  alias Bastion.{Access, Accounts, Fleet}

  test "демо создаёт дерево, устройства и права; повторно — отказ" do
    {:ok, other} = Fleet.create_folder(system(), "Своя папка")

    assert {:ok, staff} = Bastion.Demo.seed()
    assert Enum.map(staff, &elem(&1, 0)) == ~w(petrov sidorov ivanov kozlov)

    overview = Fleet.overview(system())
    assert length(overview.requests) == 2
    assert overview.total == 9
    assert other.id in Enum.map(overview.folders, & &1.id)

    sidorov = Enum.find(Accounts.list_users(), &(&1.username == "sidorov"))
    names = Fleet.overview(Access.actor(sidorov)).devices |> Map.values() |> List.flatten()
    assert names |> Enum.map(& &1.name) |> Enum.sort() == ~w(fw-core-01 rt-core-01 sw-a-301-core)

    assert {:error, :already_seeded} = Bastion.Demo.seed()
  end
end
