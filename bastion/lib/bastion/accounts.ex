defmodule Bastion.Accounts do
  use Boundary,
    top_level?: true,
    deps: [Bastion.Repo, Bastion.Events, Bastion.Access],
    exports: [User, AccessEvent, Events.SessionsClosed, Events.UsersChanged]

  alias Bastion.Accounts.Application.{AccessJournal, Authentication, Journal, Provisioning, Staff}
  alias Bastion.Accounts.Domain.PasswordPolicy
  alias Bastion.Accounts.Infrastructure.ThrottleStore

  @type current :: Authentication.current()

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [[ThrottleStore, AccessJournal], [strategy: :one_for_one, name: __MODULE__.Supervisor]]}
    }
  end

  def subscribe, do: Bastion.Events.subscribe(:accounts)

  def subscribe(user_id), do: Bastion.Events.subscribe({:user, user_id})

  @spec login(String.t(), String.t(), String.t()) ::
          {:ok, binary()}
          | {:error, :invalid_credentials | :blocked}
          | {:error, {:locked, pos_integer()}}
  defdelegate login(username, password, remote_ip), to: Authentication

  @spec user_by_session(binary() | nil, keyword()) :: current() | nil
  defdelegate user_by_session(token, opts \\ []), to: Authentication, as: :user_by_token

  @spec session_id(binary()) :: String.t()
  defdelegate session_id(token), to: Authentication

  @spec logout(binary() | nil) :: :ok
  defdelegate logout(token), to: Authentication

  @spec logout_all() :: :ok
  defdelegate logout_all(), to: Authentication

  @spec session_idle_timeout() :: pos_integer()
  defdelegate session_idle_timeout(), to: Authentication, as: :idle_timeout_s

  @spec password_min_length() :: pos_integer()
  defdelegate password_min_length(), to: PasswordPolicy, as: :min_length

  @spec ensure_admin(String.t() | nil, String.t() | nil, keyword()) :: Provisioning.result()
  defdelegate ensure_admin(username, password, opts \\ []), to: Provisioning

  defdelegate list_users(), to: Staff, as: :list
  defdelegate get_user(id), to: Staff, as: :get
  defdelegate create_user(actor, username), to: Staff, as: :create
  defdelegate reset_password(actor, id), to: Staff
  defdelegate block(actor, id), to: Staff
  defdelegate unblock(actor, id), to: Staff
  defdelegate change_password(actor, current, new), to: Staff

  @spec list_access_events(pos_integer()) :: [Bastion.Accounts.AccessEvent.t()]
  defdelegate list_access_events(limit \\ 200), to: Journal, as: :list

  @spec sync_journal() :: :ok
  defdelegate sync_journal(), to: AccessJournal, as: :sync
end
