defmodule Bastion.Console.Events.ConsoleTaken do
  @enforce_keys [:id]
  defstruct [:id]
  @type t :: %__MODULE__{id: String.t()}
end
