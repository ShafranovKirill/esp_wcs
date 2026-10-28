defmodule Bastion.Demo do
  use Boundary, top_level?: true, deps: [Bastion.Accounts, Bastion.Access, Bastion.Fleet]

  alias Bastion.{Access, Accounts, Fleet}

  @tree [
    {"Здание А",
     [
       {"Этаж 1", [{"Кабинет 101", []}, {"Кабинет 102", []}]},
       {"Этаж 3", [{"Серверная 301", []}]}
     ]},
    {"Здание Б", [{"Этаж 2", []}]},
    {"Ядро сети", []}
  ]

  @devices [
    {"sw-a-101", ["Кабинет 101"], :approved},
    {"sw-a-102", ["Кабинет 102"], :approved},
    {"sw-a-floor1", ["Этаж 1"], :approved},
    {"sw-a-301-core", ["Серверная 301", "Ядро сети"], :approved},
    {"rt-core-01", ["Ядро сети"], :approved},
    {"fw-core-01", ["Ядро сети"], :approved},
    {"sw-b-201", ["Этаж 2"], :approved},
    {"sw-a-old", ["Этаж 1"], :revoked},
    {"lab-sw-01", [], :approved},
    {"new-sw-01", [], :pending},
    {"new-sw-02", [], :pending}
  ]

  @staff [
    {"petrov", nil, "engineer", "Этаж 3"},
    {"sidorov", nil, "viewer", "Ядро сети"},
    {"ivanov", "Сетевики А", nil, nil},
    {"kozlov", "Сетевики А", nil, nil}
  ]

  @groups [{"Сетевики А", "operator", "Здание А"}]

  @type result :: {:ok, [{String.t(), String.t()}]} | {:error, :already_seeded}

  @spec seed() :: result()
  def seed do
    roots = for {name, _} <- @tree, do: String.downcase(name)
    usernames = for {name, _, _, _} <- @staff, do: name

    seeded? =
      Enum.any?(
        Fleet.list_folders(),
        &(&1.parent_id == nil and String.downcase(&1.name) in roots)
      ) or
        Enum.any?(Accounts.list_users(), &(&1.username in usernames))

    if seeded? do
      {:error, :already_seeded}
    else
      actor = Access.system()
      folders = create_tree(actor, @tree, nil, %{})
      Enum.each(@devices, &create_device(actor, &1, folders))
      roles = Map.new(Access.list_roles(), &{&1.builtin, &1.id})
      groups = Map.new(@groups, &create_group(actor, &1, roles, folders))
      {:ok, Enum.map(@staff, &create_user(actor, &1, roles, folders, groups))}
    end
  end

  defp create_tree(actor, nodes, parent_id, acc) do
    Enum.reduce(nodes, acc, fn {name, children}, acc ->
      {:ok, folder} = Fleet.create_folder(actor, name, parent_id)
      create_tree(actor, children, folder.id, Map.put(acc, name, folder.id))
    end)
  end

  defp create_device(actor, {name, folder_names, status}, folders) do
    device_id = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)

    csr =
      X509.PrivateKey.new_ec(:secp256r1)
      |> X509.CSR.new("/CN=#{device_id}")
      |> X509.CSR.to_pem()

    {:ok, :pending} =
      Fleet.submit_request(%{
        device_id: device_id,
        name: name,
        csr_pem: csr,
        firmware_version: "1.0.0",
        ip: "192.168.1.#{:rand.uniform(200) + 20}"
      })

    device = Fleet.find_by_device_id(device_id)

    if status != :pending do
      {:ok, _} = Fleet.approve(actor, device.id, device.device_code)
      {:ok, _} = Fleet.set_folders(actor, device.id, Enum.map(folder_names, &folders[&1]))
    end

    if status == :revoked, do: {:ok, _} = Fleet.revoke(actor, device.id)
  end

  defp create_group(actor, {name, role, folder}, roles, folders) do
    {:ok, group} = Access.create_group(actor, name)

    {:ok, _} =
      Access.grant(actor, %{group_id: group.id, role_id: roles[role], folder_id: folders[folder]})

    {name, group.id}
  end

  defp create_user(actor, {username, group, role, folder}, roles, folders, groups) do
    {:ok, user, password} = Accounts.create_user(actor, username)

    if group, do: :ok = Access.add_member(actor, groups[group], user.id)

    if role,
      do:
        {:ok, _} =
          Access.grant(actor, %{
            user_id: user.id,
            role_id: roles[role],
            folder_id: folders[folder]
          })

    {username, password}
  end
end
