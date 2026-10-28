defmodule Bastion.Accounts.Application.Authentication do
  import Ecto.Query

  alias Bastion.Accounts.Application.Journal
  alias Bastion.Accounts.Domain.Username
  alias Bastion.Accounts.Events.SessionsClosed
  alias Bastion.Accounts.Infrastructure.{Password, SessionRecord, ThrottleStore, UserRecord}
  alias Bastion.Repo

  @idle_timeout_s 30 * 60
  @touch_every_s 60

  @type current :: %{id: String.t(), username: String.t()}

  @spec idle_timeout_s() :: pos_integer()
  def idle_timeout_s, do: @idle_timeout_s

  @spec login(String.t(), String.t(), String.t()) ::
          {:ok, binary()}
          | {:error, :invalid_credentials | :blocked}
          | {:error, {:locked, pos_integer()}}
  def login(username, password, remote_ip) do
    keys = throttle_keys(username, remote_ip)

    case keys |> Enum.map(&ThrottleStore.wait_seconds/1) |> Enum.max() do
      0 -> check_password(username, password, remote_ip, keys)
      wait -> {:error, {:locked, wait}}
    end
  end

  defp check_password(username, password, remote_ip, keys) do
    user = Username.valid?(username) && find_user(username)

    cond do
      not Password.verify(password, user && user.password_hash) ->
        Journal.record(:login_failed,
          user_id: user && user.id,
          username: username,
          remote_ip: remote_ip
        )

        case keys |> Enum.map(&ThrottleStore.failure/1) |> Enum.max() do
          0 -> {:error, :invalid_credentials}
          wait -> {:error, {:locked, wait}}
        end

      user.blocked_at ->
        Journal.record(:login_failed,
          user_id: user.id,
          username: user.username,
          remote_ip: remote_ip,
          data: %{reason: "blocked"}
        )

        {:error, :blocked}

      true ->
        Enum.each(keys, &ThrottleStore.reset/1)
        Journal.record(:login, user_id: user.id, username: user.username, remote_ip: remote_ip)
        {:ok, create_session(user, remote_ip)}
    end
  end

  defp throttle_keys(username, remote_ip) do
    user_key =
      if is_binary(username), do: "user:" <> String.slice(Username.normalize(username), 0, 64)

    Enum.reject(["ip:" <> remote_ip, user_key], &is_nil/1)
  end

  @spec user_by_token(binary() | nil, keyword()) :: current() | nil
  def user_by_token(token, opts \\ [])

  def user_by_token(token, opts) when is_binary(token) do
    now = DateTime.utc_now(:second)
    expired_before = DateTime.add(now, -@idle_timeout_s)

    query =
      from s in SessionRecord,
        join: u in assoc(s, :user),
        where: s.token_hash == ^hash(token) and is_nil(u.blocked_at),
        select: {s, u}

    case Repo.one(query) do
      {session, user} ->
        if DateTime.compare(session.last_seen_at, expired_before) == :gt do
          if Keyword.get(opts, :touch, true), do: maybe_touch(session, now)
          %{id: user.id, username: user.username}
        else
          Repo.delete(session)
          nil
        end

      nil ->
        nil
    end
  end

  def user_by_token(_, _), do: nil

  @spec session_id(binary()) :: String.t()
  def session_id(token), do: Base.url_encode64(hash(token), padding: false)

  @spec logout(binary() | nil) :: :ok
  def logout(token) when is_binary(token) do
    query =
      from s in SessionRecord,
        join: u in assoc(s, :user),
        where: s.token_hash == ^hash(token),
        select: {s.id, u.id, u.username}

    case Repo.one(query) do
      {id, user_id, username} ->
        Repo.delete_all(from s in SessionRecord, where: s.id == ^id)
        Journal.record(:logout, user_id: user_id, username: username)

      nil ->
        :ok
    end

    :ok
  end

  def logout(_), do: :ok

  @spec close_sessions(String.t()) :: :ok
  def close_sessions(user_id) do
    Repo.delete_all(from s in SessionRecord, where: s.user_id == ^user_id)
    Bastion.Events.publish({:user, user_id}, %SessionsClosed{user_id: user_id})
    :ok
  end

  @spec logout_all() :: :ok
  def logout_all do
    Repo.delete_all(SessionRecord)
    :ok
  end

  defp find_user(username) do
    normalized = Username.normalize(username)
    Repo.one(from u in UserRecord, where: fragment("lower(?)", u.username) == ^normalized)
  end

  defp create_session(user, remote_ip) do
    token = :crypto.strong_rand_bytes(32)

    Repo.insert!(%SessionRecord{
      user_id: user.id,
      token_hash: hash(token),
      last_seen_at: DateTime.utc_now(:second),
      remote_ip: remote_ip
    })

    token
  end

  defp maybe_touch(session, now) do
    if DateTime.diff(now, session.last_seen_at) >= @touch_every_s do
      Repo.update_all(from(s in SessionRecord, where: s.id == ^session.id),
        set: [last_seen_at: now]
      )
    end
  end

  defp hash(token), do: :crypto.hash(:sha256, token)
end
