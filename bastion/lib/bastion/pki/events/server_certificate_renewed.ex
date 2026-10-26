defmodule Bastion.PKI.Events.ServerCertificateRenewed do
  @moduledoc "Сертификат сервера перевыпущен: TLS-слушатели должны его перечитать"
  @enforce_keys [:reason]
  defstruct [:reason]

  @type t :: %__MODULE__{reason: :other_ca | :expiring | :hosts_changed}
end
