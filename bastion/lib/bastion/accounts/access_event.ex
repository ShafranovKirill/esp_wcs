defmodule Bastion.Accounts.AccessEvent do
  @types ~w(login login_failed logout user_created password_changed password_reset blocked unblocked)a

  @type type ::
          :login
          | :login_failed
          | :logout
          | :user_created
          | :password_changed
          | :password_reset
          | :blocked
          | :unblocked

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          user_id: String.t() | nil,
          actor_id: String.t() | nil,
          username: String.t() | nil,
          actor: String.t() | nil,
          remote_ip: String.t() | nil,
          data: map(),
          at: DateTime.t()
        }
  defstruct [:id, :type, :user_id, :actor_id, :username, :actor, :remote_ip, :data, :at]

  @spec types() :: [type()]
  def types, do: @types
end
