defmodule Bastion.Accounts.StaffTest do
  use Bastion.DataCase, async: false

  alias Bastion.Accounts

  defp actor(user), do: Bastion.Access.actor(user)
  alias Bastion.Accounts.Events.{SessionsClosed, UsersChanged}

  @password "correct horse battery"

  defp ip, do: "10.1.0.#{System.unique_integer([:positive]) |> rem(250)}"

  setup do
    {:ok, :created} = Accounts.ensure_admin("admin", @password)
    [admin] = Accounts.list_users()
    %{admin: admin}
  end

  test "создание: пароль генерируется, вход работает, логин уникален без учёта регистра", %{
    admin: admin
  } do
    Accounts.subscribe()
    assert {:ok, user, password} = Accounts.create_user(actor(admin), "Ivanov")
    assert String.length(password) == 16
    assert_receive {:event, %UsersChanged{}}
    assert {:ok, _} = Accounts.login("ivanov", password, ip())
    assert is_nil(user.password_changed_at)

    assert {:error, :username_taken} = Accounts.create_user(actor(admin), "IVANOV")
    assert {:error, :invalid_username} = Accounts.create_user(actor(admin), "иван ов")
    assert {:error, :invalid_username} = Accounts.create_user(actor(admin), "")
  end

  test "блокировка закрывает сессии и не даёт войти; разблокировка возвращает вход", %{
    admin: admin
  } do
    {:ok, user, password} = Accounts.create_user(actor(admin), "petrov")
    {:ok, token} = Accounts.login("petrov", password, ip())
    Accounts.subscribe(user.id)

    assert {:ok, _} = Accounts.block(actor(admin), user.id)
    assert_receive {:event, %SessionsClosed{user_id: id}} when id == user.id
    assert Accounts.user_by_session(token) == nil
    assert {:error, :blocked} = Accounts.login("petrov", password, ip())
    assert {:error, :invalid_credentials} = Accounts.login("petrov", "wrong password", ip())

    assert {:ok, _} = Accounts.unblock(actor(admin), user.id)
    assert {:ok, _} = Accounts.login("petrov", password, ip())
  end

  test "нельзя заблокировать себя и последнего активного суперадмина", %{admin: admin} do
    assert {:error, :self} = Accounts.block(actor(admin), admin.id)

    {:ok, other, _} = Accounts.create_user(actor(admin), "other")
    assert {:error, :forbidden} = Accounts.block(actor(other), admin.id)
    assert {:ok, _} = Accounts.block(actor(admin), other.id)
    assert {:ok, _} = Accounts.unblock(actor(admin), other.id)

    :ok = Bastion.Access.grant_superadmin(other.id)
    assert {:ok, _} = Accounts.block(actor(other), admin.id)
    assert {:error, :last_user} = Accounts.block(actor(admin), other.id)
    assert {:error, :user_not_found} = Accounts.block(actor(admin), Ecto.UUID.generate())
  end

  test "сброс пароля: старый не подходит, сессии закрыты, отметка «выданный пароль»", %{
    admin: admin
  } do
    {:ok, user, password} = Accounts.create_user(actor(admin), "sidorov")

    :ok =
      Accounts.change_password(
        actor(user),
        password,
        "my own long password"
      )

    {:ok, token} = Accounts.login("sidorov", "my own long password", ip())

    assert {:ok, user, new_password} = Accounts.reset_password(actor(admin), user.id)
    assert new_password != password
    assert is_nil(user.password_changed_at)
    assert Accounts.user_by_session(token) == nil

    assert {:error, :invalid_credentials} =
             Accounts.login("sidorov", "my own long password", ip())

    assert {:ok, _} = Accounts.login("sidorov", new_password, ip())
  end

  test "смена своего пароля проверяет текущий и политику", %{admin: admin} do
    assert {:error, :invalid_current} =
             Accounts.change_password(actor(admin), "wrong", "new long password!")

    assert {:error, :too_short} = Accounts.change_password(actor(admin), @password, "short")
    assert {:error, :placeholder} = Accounts.change_password(actor(admin), @password, "password")
    assert {:error, :same} = Accounts.change_password(actor(admin), @password, @password)
    assert :ok = Accounts.change_password(actor(admin), @password, "new long password!")
    assert Accounts.get_user(admin.id).password_changed_at
    assert {:ok, _} = Accounts.login("admin", "new long password!", ip())
  end

  test "после 5 ошибок по одному логину пауза и с другого адреса", %{admin: admin} do
    {:ok, _, password} = Accounts.create_user(actor(admin), "target")

    for _ <- 1..5,
        do: assert({:error, :invalid_credentials} = Accounts.login("target", "wrong", ip()))

    assert {:error, {:locked, 5}} = Accounts.login("target", "wrong", ip())

    assert {:error, {:locked, _}} = Accounts.login("target", password, ip())
    assert {:ok, _} = Accounts.login("admin", @password, ip())
  end

  test "журнал доступа: кто, над кем, откуда", %{admin: admin} do
    {:ok, user, password} = Accounts.create_user(actor(admin), "kozlov")
    {:ok, _} = Accounts.login("kozlov", password, "10.9.9.9")
    {:error, _} = Accounts.login("nobody", "wrong", "10.9.9.8")
    {:ok, _} = Accounts.block(actor(admin), user.id)

    events = Accounts.list_access_events()
    assert [%{type: :blocked, actor: "admin", username: "kozlov"} | _] = events

    assert Enum.any?(
             events,
             &match?(%{type: :login, username: "kozlov", remote_ip: "10.9.9.9"}, &1)
           )

    assert Enum.any?(
             events,
             &match?(%{type: :login_failed, username: "nobody", user_id: nil}, &1)
           )

    assert Enum.any?(events, &match?(%{type: :user_created, actor: "admin"}, &1))
  end
end
