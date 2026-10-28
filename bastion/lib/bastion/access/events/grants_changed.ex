defmodule Bastion.Access.Events.GrantsChanged do
  @type change ::
          :role_created
          | :role_updated
          | :role_deleted
          | :group_created
          | :group_renamed
          | :group_deleted
          | :member_added
          | :member_removed
          | :access_granted
          | :access_revoked

  @type t :: %__MODULE__{
          change: change() | nil,
          actor_id: String.t() | nil,
          user_id: String.t() | nil,
          data: map()
        }
  defstruct [:change, :actor_id, :user_id, data: %{}]
end
