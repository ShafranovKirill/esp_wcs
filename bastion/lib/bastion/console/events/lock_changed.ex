defmodule Bastion.Console.Events.LockChanged do
  @enforce_keys [:id, :owned]
  defstruct [:id, :owned]
  @type t :: %__MODULE__{id: String.t(), owned: boolean()}
end
