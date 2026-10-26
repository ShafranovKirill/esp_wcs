defmodule Bastion.Fleet.DeviceEvent do
  @moduledoc """
  Запись журнала устройства (вкладка «Журнал»).

  Типы: `requested`, `approved`, `rejected`, `revoked`, `renamed`, `moved`,
  `connected`, `disconnected`, `console_taken`, `console_released`, `command`.
  """

  @types ~w(requested approved rejected revoked renamed moved connected disconnected console_taken console_released command)a

  @type type ::
          :requested
          | :approved
          | :rejected
          | :revoked
          | :renamed
          | :moved
          | :connected
          | :disconnected
          | :console_taken
          | :console_released
          | :command

  @type t :: %__MODULE__{id: String.t(), type: type(), data: map(), at: DateTime.t()}
  defstruct [:id, :type, :data, :at]

  @spec types() :: [type()]
  def types, do: @types
end
