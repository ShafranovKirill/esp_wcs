defmodule Bastion.Fleet.Events.DeviceApproved do
  @enforce_keys [:id, :device_id, :certificate_pem]
  defstruct [:id, :device_id, :certificate_pem]
  @type t :: %__MODULE__{id: String.t(), device_id: String.t(), certificate_pem: String.t()}
end
