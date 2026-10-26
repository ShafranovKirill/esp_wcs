defmodule Bastion.Fleet.Events.DeviceRequested do
  @moduledoc "Устройство подало заявку"
  @enforce_keys [:id, :device_id]
  defstruct [:id, :device_id]
  @type t :: %__MODULE__{id: String.t(), device_id: String.t()}
end
