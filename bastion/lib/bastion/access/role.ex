defmodule Bastion.Access.Role do
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          builtin: String.t() | nil,
          actions: [String.t()]
        }
  defstruct [:id, :name, :builtin, actions: []]
end
