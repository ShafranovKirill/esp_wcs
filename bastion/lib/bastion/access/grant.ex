defmodule Bastion.Access.Grant do
  @type t :: %__MODULE__{
          id: String.t(),
          role_id: String.t(),
          user_id: String.t() | nil,
          group_id: String.t() | nil,
          folder_id: String.t() | nil
        }
  defstruct [:id, :role_id, :user_id, :group_id, :folder_id]
end
