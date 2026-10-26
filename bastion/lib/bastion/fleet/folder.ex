defmodule Bastion.Fleet.Folder do
  @moduledoc "Папка для группировки устройств на главной (один уровень, без вложенности)"

  @type t :: %__MODULE__{id: String.t(), name: String.t()}
  defstruct [:id, :name]
end
