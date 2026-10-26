defmodule Bastion.Link.Events.PresenceChanged do
  @moduledoc "Связь с устройством изменилась (`online` — сейчас на связи)"
  @enforce_keys [:id, :online]
  defstruct [:id, :online]
  @type t :: %__MODULE__{id: String.t(), online: boolean()}
end
