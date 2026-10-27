defmodule Bastion.Control.Domain.Wifi do
  @ssid_max 32
  @password_min 8
  @password_max 63

  @enforce_keys [:ssid, :password]
  defstruct @enforce_keys

  @type t :: %__MODULE__{ssid: String.t(), password: String.t()}

  @spec ssid_max_length() :: pos_integer()
  def ssid_max_length, do: @ssid_max

  @spec new(map()) :: {:ok, t()} | {:error, :invalid_ssid | :invalid_password}
  def new(params) do
    ssid = Map.get(params, "ssid", "")
    password = Map.get(params, "password", "")

    cond do
      not is_binary(ssid) or byte_size(ssid) not in 1..@ssid_max or not String.printable?(ssid) ->
        {:error, :invalid_ssid}

      not is_binary(password) or
          (password != "" and byte_size(password) not in @password_min..@password_max) ->
        {:error, :invalid_password}

      true ->
        {:ok, %__MODULE__{ssid: ssid, password: password}}
    end
  end

  @spec to_args(t()) :: map()
  def to_args(%__MODULE__{} = wifi), do: %{ssid: wifi.ssid, password: wifi.password}
end
