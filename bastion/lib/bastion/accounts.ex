defmodule Bastion.Accounts do
  use Boundary, top_level?: true, deps: [Bastion.Repo]

  alias Bastion.Accounts.Application.{Authentication, Provisioning}
  alias Bastion.Accounts.Domain.PasswordPolicy
  alias Bastion.Accounts.Infrastructure.ThrottleStore

  @type admin :: %{id: String.t(), username: String.t()}

  def child_spec(_opts) do
    %{id: __MODULE__, start: {ThrottleStore, :start_link, [[]]}}
  end

  @spec login(String.t(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, :invalid_credentials} | {:error, {:locked, pos_integer()}}
  defdelegate login(username, password, remote_ip), to: Authentication

  @spec admin_by_session(binary() | nil, keyword()) :: admin() | nil
  defdelegate admin_by_session(token, opts \\ []), to: Authentication, as: :admin_by_token

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
end
