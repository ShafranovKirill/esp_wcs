defmodule Bastion.Link.Events.PresenceChanged do
  @enforce_keys [:id, :online]
  defstruct [:id, :online]
  @type t :: %__MODULE__{id: String.t(), online: boolean()}
end
