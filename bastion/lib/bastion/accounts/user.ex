defmodule Bastion.Accounts.User do
  @type t :: %__MODULE__{
          id: String.t(),
          username: String.t(),
          blocked_at: DateTime.t() | nil,
          password_changed_at: DateTime.t() | nil,
          inserted_at: DateTime.t()
        }
  defstruct [:id, :username, :blocked_at, :password_changed_at, :inserted_at]

  @spec blocked?(t()) :: boolean()
  def blocked?(%__MODULE__{blocked_at: at}), do: not is_nil(at)
end
