defmodule Bastion.AccountsTest do
  use Bastion.DataCase, async: false

  alias Bastion.Accounts

  @password "correct horse battery"

  defp ip, do: "10.0.0.#{System.unique_integer([:positive]) |> rem(250)}"

  describe "ensure_admin/3" do
    test "создаёт администратора, повторный вызов ничего не меняет" do
      assert {:ok, :created} = Accounts.ensure_admin("admin", @password)
      assert {:ok, :unchanged} = Accounts.ensure_admin("admin", "another long password")
      assert {:ok, _} = Accounts.login("admin", @password, ip())
    end

    test "reset перезаписывает пароль и завершает сессии" do
      {:ok, :created} = Accounts.ensure_admin("admin", @password)
      {:ok, token} = Accounts.login("admin", @password, ip())

      assert {:ok, :reset} = Accounts.ensure_admin("admin", "brand new password", reset: true)
      assert Accounts.admin_by_session(token) == nil
      assert {:error, :invalid_credentials} = Accounts.login("admin", @password, ip())
      assert {:ok, _} = Accounts.login("admin", "brand new password", ip())
    end

    test "не принимает пароль из шаблона, короткий и пустой" do
      assert {:error, :placeholder} = Accounts.ensure_admin("admin", "change-me")
      assert {:error, :too_short} = Accounts.ensure_admin("admin", "short")
      assert {:error, :missing} = Accounts.ensure_admin("admin", nil)
      assert {:error, :invalid_username} = Accounts.ensure_admin("ad min", @password)
    end

    test "в разработке принимает слабый пароль, но не пустой" do
      Application.put_env(:bastion, :weak_admin_password, true)
      on_exit(fn -> Application.delete_env(:bastion, :weak_admin_password) end)

      assert {:error, :missing} = Accounts.ensure_admin("admin", "")
      assert {:ok, :created} = Accounts.ensure_admin("admin", "admin")
      assert {:ok, _} = Accounts.login("admin", "admin", ip())
    end
  end

  describe "login/3 и сессии" do
    setup do
      {:ok, :created} = Accounts.ensure_admin("Admin", @password)
      :ok
    end

    test "логин без учёта регистра, токен даёт администратора" do
      assert {:ok, token} = Accounts.login("admin", @password, ip())
      assert %{username: "Admin"} = Accounts.admin_by_session(token)
    end

    test "неверный пароль и несуществующий логин — одна и та же ошибка" do
      assert {:error, :invalid_credentials} = Accounts.login("Admin", "wrong password!", ip())
      assert {:error, :invalid_credentials} = Accounts.login("nobody", @password, ip())
    end

    test "после 5 ошибок с одного адреса — пауза, даже для верного пароля; другой адрес не затронут" do
      attacker = ip()

      for _ <- 1..5,
          do: assert({:error, :invalid_credentials} = Accounts.login("Admin", "wrong", attacker))

      assert {:error, {:locked, 5}} = Accounts.login("Admin", "wrong", attacker)
      assert {:error, {:locked, _}} = Accounts.login("Admin", @password, attacker)
      assert {:ok, _} = Accounts.login("Admin", @password, ip())
    end

    test "сессия истекает после 30 минут бездействия" do
      {:ok, token} = Accounts.login("Admin", @password, ip())
      long_ago = DateTime.add(DateTime.utc_now(:second), -31 * 60)
      Repo.update_all(Bastion.Accounts.Infrastructure.AdminSession, set: [last_seen_at: long_ago])

      assert Accounts.admin_by_session(token) == nil
    end

    test "проверка без продления не двигает время сессии" do
      {:ok, token} = Accounts.login("Admin", @password, ip())
      almost = DateTime.add(DateTime.utc_now(:second), -29 * 60)
      Repo.update_all(Bastion.Accounts.Infrastructure.AdminSession, set: [last_seen_at: almost])

      assert Accounts.admin_by_session(token, touch: false)
      assert [%{last_seen_at: ^almost}] = Repo.all(Bastion.Accounts.Infrastructure.AdminSession)

      assert Accounts.admin_by_session(token)
      assert [%{last_seen_at: touched}] = Repo.all(Bastion.Accounts.Infrastructure.AdminSession)
      assert DateTime.compare(touched, almost) == :gt
    end

    test "выход удаляет сессию, токен в БД не хранится" do
      {:ok, token} = Accounts.login("Admin", @password, ip())

      refute Enum.any?(
               Repo.all(Bastion.Accounts.Infrastructure.AdminSession),
               &(&1.token_hash == token)
             )

      :ok = Accounts.logout(token)
      assert Accounts.admin_by_session(token) == nil
    end

    test "мусорный токен" do
      assert Accounts.admin_by_session("garbage") == nil
      assert Accounts.admin_by_session(nil) == nil
    end
  end
end
