defmodule Bastion.Fleet.Events.DeviceChanged do
  @enforce_keys [:id, :change]
  defstruct [:id, :change]

  @type t :: %__MODULE__{
          id: String.t(),
          change:
            :requested | :approved | :rejected | :revoked | :deleted | :renamed | :moved | :seen
        }
end
