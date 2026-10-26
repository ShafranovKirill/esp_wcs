defmodule Bastion.Accounts do
  @moduledoc """
  Контекст Accounts — вход единственного администратора (`docs/bastion.md`).

  Логин и пароль задаются в `.env` и попадают в БД задачей `mix bastion.admin`
  (в релизе — `Bastion.Release.admin/1`); хранится только хэш Argon2.
  """
  use Boundary, top_level?: true, deps: [Bastion.Repo]

  alias Bastion.Accounts.Application.{Authentication, Provisioning}
  alias Bastion.Accounts.Domain.PasswordPolicy
  alias Bastion.Accounts.Infrastructure.ThrottleStore

  @type admin :: %{id: String.t(), username: String.t()}

  @doc "Процессы контекста (счётчики попыток входа)"
  def child_spec(_opts) do
    %{id: __MODULE__, start: {ThrottleStore, :start_link, [[]]}}
  end

  @doc """
  Вход. `remote_ip` — для защиты от перебора: после 5 ошибок с одного адреса —
  нарастающая пауза.
  """
  @spec login(String.t(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, :invalid_credentials} | {:error, {:locked, pos_integer()}}
  defdelegate login(username, password, remote_ip), to: Authentication

  @doc """
  Администратор по токену сессии. По умолчанию продлевает сессию; `touch: false` —
  только проверить (фоновые проверки открытых вкладок). `nil` — нет или истекла.
  """
  @spec admin_by_session(binary() | nil, keyword()) :: admin() | nil
  defdelegate admin_by_session(token, opts \\ []), to: Authentication, as: :admin_by_token

  @doc "Идентификатор сессии (без секрета) — для отключения её вкладок при выходе"
  @spec session_id(binary()) :: String.t()
  defdelegate session_id(token), to: Authentication

  @spec logout(binary() | nil) :: :ok
  defdelegate logout(token), to: Authentication

  @spec logout_all() :: :ok
  defdelegate logout_all(), to: Authentication

  @doc "Бездействие, после которого сессия истекает, секунд"
  @spec session_idle_timeout() :: pos_integer()
  defdelegate session_idle_timeout(), to: Authentication, as: :idle_timeout_s

  @doc "Минимальная длина пароля администратора"
  @spec password_min_length() :: pos_integer()
  defdelegate password_min_length(), to: PasswordPolicy, as: :min_length

  @doc "Создать администратора из `.env`; `reset: true` — перезаписать пароль"
  @spec ensure_admin(String.t() | nil, String.t() | nil, keyword()) :: Provisioning.result()
  defdelegate ensure_admin(username, password, opts \\ []), to: Provisioning
end
