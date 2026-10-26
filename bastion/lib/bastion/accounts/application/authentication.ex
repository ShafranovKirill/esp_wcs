defmodule Bastion.Accounts.Application.Authentication do
  @moduledoc """
  Вход, проверка и завершение сессий администратора.

  Токен сессии — 32 случайных байта; в cookie лежит сам токен, в БД — SHA-256 от
  него (утечка БД не даёт войти). Сессия истекает после `@idle_timeout_s`
  бездействия.
  """
  import Ecto.Query

  alias Bastion.Accounts.Domain.Username
  alias Bastion.Accounts.Infrastructure.{Admin, AdminSession, Password, ThrottleStore}
  alias Bastion.Repo

  @idle_timeout_s 30 * 60
  # Не писать last_seen_at в БД на каждый запрос
  @touch_every_s 60

  @spec idle_timeout_s() :: pos_integer()
  def idle_timeout_s, do: @idle_timeout_s

  @spec login(String.t(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, :invalid_credentials} | {:error, {:locked, pos_integer()}}
  def login(username, password, remote_ip) do
    case ThrottleStore.wait_seconds(remote_ip) do
      0 -> check_password(username, password, remote_ip)
      wait -> {:error, {:locked, wait}}
    end
  end

  defp check_password(username, password, remote_ip) do
    admin = Username.valid?(username) && find_admin(username)

    if Password.verify(password, admin && admin.password_hash) do
      ThrottleStore.reset(remote_ip)
      {:ok, create_session(admin, remote_ip)}
    else
      case ThrottleStore.failure(remote_ip) do
        0 -> {:error, :invalid_credentials}
        wait -> {:error, {:locked, wait}}
      end
    end
  end

  @doc """
  Администратор по токену. `touch: true` — продлить сессию (действие пользователя);
  фоновые проверки открытых вкладок вызывают без продления, иначе сессия не истечёт
  никогда. `nil` — нет сессии или истекла.
  """
  @spec admin_by_token(binary() | nil, keyword()) :: %{id: String.t(), username: String.t()} | nil
  def admin_by_token(token, opts \\ [])

  def admin_by_token(token, opts) when is_binary(token) do
    now = DateTime.utc_now(:second)
    expired_before = DateTime.add(now, -@idle_timeout_s)

    query =
      from s in AdminSession,
        join: a in assoc(s, :admin),
        where: s.token_hash == ^hash(token),
        select: {s, a}

    case Repo.one(query) do
      {session, admin} ->
        if DateTime.compare(session.last_seen_at, expired_before) == :gt do
          if Keyword.get(opts, :touch, true), do: maybe_touch(session, now)
          %{id: admin.id, username: admin.username}
        else
          Repo.delete(session)
          nil
        end

      nil ->
        nil
    end
  end

  def admin_by_token(_, _), do: nil

  @doc "Идентификатор сессии для отключения её LiveView-вкладок при выходе"
  @spec session_id(binary()) :: String.t()
  def session_id(token), do: Base.url_encode64(hash(token), padding: false)

  @spec logout(binary() | nil) :: :ok
  def logout(token) when is_binary(token) do
    Repo.delete_all(from s in AdminSession, where: s.token_hash == ^hash(token))
    :ok
  end

  def logout(_), do: :ok

  @spec logout_all() :: :ok
  def logout_all do
    Repo.delete_all(AdminSession)
    :ok
  end

  defp find_admin(username) do
    normalized = Username.normalize(username)
    Repo.one(from a in Admin, where: fragment("lower(?)", a.username) == ^normalized)
  end

  defp create_session(admin, remote_ip) do
    token = :crypto.strong_rand_bytes(32)

    Repo.insert!(%AdminSession{
      admin_id: admin.id,
      token_hash: hash(token),
      last_seen_at: DateTime.utc_now(:second),
      remote_ip: remote_ip
    })

    token
  end

  defp maybe_touch(session, now) do
    if DateTime.diff(now, session.last_seen_at) >= @touch_every_s do
      Repo.update_all(from(s in AdminSession, where: s.id == ^session.id),
        set: [last_seen_at: now]
      )
    end
  end

  defp hash(token), do: :crypto.hash(:sha256, token)
end
