defmodule Bastion.Fleet.Domain.DeviceId do
  @spec normalize(term()) :: {:ok, String.t()} | {:error, :invalid_device_id}
  def normalize(id) when is_binary(id) do
    id = String.downcase(id)
    if id =~ ~r/\A[0-9a-f]{12}\z/, do: {:ok, id}, else: {:error, :invalid_device_id}
  end

  def normalize(_), do: {:error, :invalid_device_id}

  @spec format_mac(String.t()) :: String.t()
  def format_mac(id),
    do: id |> String.graphemes() |> Enum.chunk_every(2) |> Enum.map_join(":", &Enum.join/1)
end
