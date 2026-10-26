defmodule Bastion.Fleet.Events.DeviceRevoked do
  @moduledoc "Устройство отозвано: соединение закрыть, сертификат больше не принимать"
  @enforce_keys [:id, :device_id]
  defstruct [:id, :device_id]
  @type t :: %__MODULE__{id: String.t(), device_id: String.t()}
end
