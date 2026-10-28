defmodule Bastion.Accounts.Application.Staff do
  import Ecto.Query

  alias Bastion.Accounts.Application.{Authentication, Journal}
  alias Bastion.Accounts.Domain.{PasswordPolicy, Username}
  alias Bastion.Accounts.Events.UsersChanged
  alias Bastion.Accounts.Infrastructure.{Password, UserRecord}
  alias Bastion.Accounts.User
  alias Bastion.Repo

  @type actor :: %{id: String.t(), username: String.t()}

  @spec list() :: [User.t()]
  def list do
    Repo.all(from u in UserRecord, order_by: fragment("lower(?)", u.username))
    |> Enum.map(&UserRecord.to_domain/1)
  end

  @spec get(String.t()) :: User.t() | nil
  def get(id) do
    case fetch(id) do
      {:ok, record} -> UserRecord.to_domain(record)
      {:error, _} -> nil
    end
  end

  @spec create(actor(), String.t()) ::
          {:ok, User.t(), String.t()} | {:error, :invalid_username | :username_taken}
  def create(actor, username) do
    username = String.trim(username || "")
    password = Password.generate()

    with true <- Username.valid?(username) || {:error, :invalid_username},
         {:ok, record} <-
           %UserRecord{}
           |> UserRecord.changeset(username, Password.hash(password))
           |> Repo.insert() do
      Journal.record(:user_created,
        user_id: record.id,
        username: record.username,
        actor_id: actor.id
      )

      changed()
      {:ok, UserRecord.to_domain(record), password}
    else
      {:error, %Ecto.Changeset{}} -> {:error, :username_taken}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec reset_password(actor(), String.t()) ::
          {:ok, User.t(), String.t()} | {:error, :user_not_found}
  def reset_password(actor, id) do
    with {:ok, record} <- fetch(id) do
      password = Password.generate()

      record =
        record
        |> Ecto.Changeset.change(password_hash: Password.hash(password), password_changed_at: nil)
        |> Repo.update!()

      Authentication.close_sessions(record.id)

      Journal.record(:password_reset,
        user_id: record.id,
        username: record.username,
        actor_id: actor.id
      )

      changed()
      {:ok, UserRecord.to_domain(record), password}
    end
  end

  @spec block(actor(), String.t()) ::
          {:ok, User.t()} | {:error, :user_not_found | :self | :last_user}
  def block(actor, id) do
    with {:ok, record} <- fetch(id),
         :ok <- not_self(actor, record),
         :ok <- not_last(record) do
      record =
        record
        |> Ecto.Changeset.change(blocked_at: DateTime.utc_now(:second))
        |> Repo.update!()

      Authentication.close_sessions(record.id)
      Journal.record(:blocked, user_id: record.id, username: record.username, actor_id: actor.id)
      changed()
      {:ok, UserRecord.to_domain(record)}
    end
  end

  @spec unblock(actor(), String.t()) :: {:ok, User.t()} | {:error, :user_not_found}
  def unblock(actor, id) do
    with {:ok, record} <- fetch(id) do
      record = record |> Ecto.Changeset.change(blocked_at: nil) |> Repo.update!()

      Journal.record(:unblocked,
        user_id: record.id,
        username: record.username,
        actor_id: actor.id
      )

      changed()
      {:ok, UserRecord.to_domain(record)}
    end
  end

  @spec change_password(actor(), String.t(), String.t()) ::
          :ok | {:error, :invalid_current | :missing | :too_short | :placeholder | :same}
  def change_password(actor, current, new) do
    with {:ok, record} <- fetch(actor.id),
         true <-
           Password.verify(current || "", record.password_hash) || {:error, :invalid_current},
         :ok <- PasswordPolicy.check(new),
         true <- new != current || {:error, :same} do
      record
      |> Ecto.Changeset.change(
        password_hash: Password.hash(new),
        password_changed_at: DateTime.utc_now(:second)
      )
      |> Repo.update!()

      Journal.record(:password_changed,
        user_id: record.id,
        username: record.username,
        actor_id: actor.id
      )

      changed()
      :ok
    else
      {:error, :user_not_found} -> {:error, :invalid_current}
      {:error, reason} -> {:error, reason}
    end
  end

  defp not_self(%{id: id}, %UserRecord{id: id}), do: {:error, :self}
  defp not_self(_, _), do: :ok

  defp not_last(record) do
    others =
      Repo.aggregate(
        from(u in UserRecord, where: u.id != ^record.id and is_nil(u.blocked_at)),
        :count
      )

    if others > 0, do: :ok, else: {:error, :last_user}
  end

  defp fetch(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %UserRecord{} = record <- Repo.get(UserRecord, uuid) do
      {:ok, record}
    else
      _ -> {:error, :user_not_found}
    end
  end

  defp changed, do: Bastion.Events.publish(:accounts, %UsersChanged{})
end
