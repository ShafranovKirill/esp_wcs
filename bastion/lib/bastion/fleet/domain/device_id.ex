defmodule Bastion.Fleet.Domain.DeviceId do
  @moduledoc "ID устройства — базовый MAC, 12 hex строчными (`7c2c678c8580`), не меняется"

  @spec normalize(term()) :: {:ok, String.t()} | {:error, :invalid_device_id}
  def normalize(id) when is_binary(id) do
    id = String.downcase(id)
    if id =~ ~r/\A[0-9a-f]{12}\z/, do: {:ok, id}, else: {:error, :invalid_device_id}
  end

  def normalize(_), do: {:error, :invalid_device_id}

  @doc "MAC в привычном виде: `7c:2c:67:8c:85:80`"
  @spec format_mac(String.t()) :: String.t()
  def format_mac(id),
    do: id |> String.graphemes() |> Enum.chunk_every(2) |> Enum.map_join(":", &Enum.join/1)
end
