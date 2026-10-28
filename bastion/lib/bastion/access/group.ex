defmodule Bastion.Access.Group do
  @type t :: %__MODULE__{id: String.t(), name: String.t(), member_ids: [String.t()]}
  defstruct [:id, :name, member_ids: []]
end
