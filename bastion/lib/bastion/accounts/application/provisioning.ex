defmodule Bastion.Accounts.Application.Provisioning do
  import Ecto.Query

  alias Bastion.Accounts.Application.Authentication
  alias Bastion.Accounts.Domain.{PasswordPolicy, Username}
  alias Bastion.Accounts.Infrastructure.{Password, UserRecord}
  alias Bastion.Repo

  @type result :: {:ok, :created | :unchanged | :reset} | {:error, atom()}

  @spec ensure_admin(String.t() | nil, String.t() | nil, keyword()) :: result()
  def ensure_admin(username, password, opts \\ []) do
    reset? = Keyword.get(opts, :reset, false)

    with :ok <- check_username(username),
         :ok <- check_password(password) do
      cond do
        Repo.aggregate(UserRecord, :count) == 0 -> create(username, password)
        reset? -> reset(username, password)
        true -> {:ok, :unchanged}
      end
    end
  end

  defp check_password(password) do
    case PasswordPolicy.check(password) do
      {:error, reason} when reason in [:too_short, :placeholder] ->
        if Application.get_env(:bastion, :weak_admin_password, false),
          do: :ok,
          else: {:error, reason}

      result ->
        result
    end
  end

  defp check_username(username) do
    if Username.valid?(username), do: :ok, else: {:error, :invalid_username}
  end

  defp create(username, password) do
    case %UserRecord{}
         |> UserRecord.changeset(username, Password.hash(password))
         |> Repo.insert() do
      {:ok, _} -> {:ok, :created}
      {:error, _} -> {:error, :insert_failed}
    end
  end

  defp reset(username, password) do
    normalized = Username.normalize(username)

    case Repo.one(from u in UserRecord, where: fragment("lower(?)", u.username) == ^normalized) do
      nil ->
        create(username, password)

      record ->
        record
        |> Ecto.Changeset.change(password_hash: Password.hash(password), blocked_at: nil)
        |> Repo.update!()

        Authentication.close_sessions(record.id)
        {:ok, :reset}
    end
  end
end
