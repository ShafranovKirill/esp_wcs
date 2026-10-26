defmodule Bastion.Accounts.Application.Provisioning do
  @moduledoc """
  Учётная запись администратора из `.env` (`BASTION_ADMIN_USERNAME`,
  `BASTION_ADMIN_PASSWORD`). Существующего администратора без `reset: true`
  не меняет: случайный повторный запуск не сбросит пароль.

  Администратор один: при `reset` прежняя запись заменяется, все сессии
  завершаются.
  """
  alias Bastion.Accounts.Domain.{PasswordPolicy, Username}
  alias Bastion.Accounts.Infrastructure.{Admin, AdminSession, Password}
  alias Bastion.Repo

  @type result :: {:ok, :created | :unchanged | :reset} | {:error, atom()}

  @spec ensure_admin(String.t() | nil, String.t() | nil, keyword()) :: result()
  def ensure_admin(username, password, opts \\ []) do
    reset? = Keyword.get(opts, :reset, false)

    with :ok <- check_username(username),
         :ok <- PasswordPolicy.check(password) do
      case Repo.all(Admin) do
        [] -> create(username, password)
        _ when reset? -> replace(username, password)
        _ -> {:ok, :unchanged}
      end
    end
  end

  defp check_username(username) do
    if Username.valid?(username), do: :ok, else: {:error, :invalid_username}
  end

  defp create(username, password) do
    case %Admin{} |> Admin.changeset(username, Password.hash(password)) |> Repo.insert() do
      {:ok, _} -> {:ok, :created}
      {:error, _} -> {:error, :insert_failed}
    end
  end

  defp replace(username, password) do
    Repo.transaction(fn ->
      Repo.delete_all(AdminSession)
      Repo.delete_all(Admin)
      Repo.insert!(Admin.changeset(%Admin{}, username, Password.hash(password)))
    end)
    |> case do
      {:ok, _} -> {:ok, :reset}
      {:error, _} -> {:error, :insert_failed}
    end
  end
end
