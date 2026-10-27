defmodule Bastion.Link.Events.ConsoleOutput do
  @enforce_keys [:id, :data]
  defstruct [:id, :data]
  @type t :: %__MODULE__{id: String.t(), data: binary()}
end
