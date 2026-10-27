defmodule Bastion.PKI.Events.ServerCertificateRenewed do
  @enforce_keys [:reason]
  defstruct [:reason]

  @type t :: %__MODULE__{reason: :other_ca | :expiring | :hosts_changed}
end
