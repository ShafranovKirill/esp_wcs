defmodule Bastion.Accounts.Events.SessionsClosed do
  defstruct [:user_id]
  @type t :: %__MODULE__{user_id: String.t()}
end
