defmodule Bastion.Console.Domain.Profiles do
  @profiles [
    %{
      id: "eltex-mes2308r",
      vendor: "Eltex",
      family: "MES",
      model: "MES2308R",
      backspace: "bs",
      line: %{baud: 115_200, data_bits: 8, parity: "none", stop_bits: 1}
    },
    %{
      id: "eltex-esr12vf",
      vendor: "Eltex",
      family: "ESR",
      model: "ESR-12VF",
      backspace: "bs",
      line: %{baud: 115_200, data_bits: 8, parity: "none", stop_bits: 1}
    }
  ]

  def all, do: @profiles

  def fetch(id) do
    case Enum.find(@profiles, &(&1.id == id)) do
      nil -> {:error, :invalid_line}
      profile -> {:ok, profile}
    end
  end
end
