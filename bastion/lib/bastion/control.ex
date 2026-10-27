defmodule Bastion.Control do
  use Boundary, top_level?: true, deps: [Bastion.Fleet, Bastion.Link]

  alias Bastion.Control.Domain.Wifi

  @spec reboot(String.t()) :: :ok | {:error, term()}
  def reboot(id) do
    with :ok <- Bastion.Link.command(id, "reboot") do
      Bastion.Fleet.record_event(id, :command, %{op: "reboot"})
    end
  end

  @spec set_wifi(String.t(), map()) :: :ok | {:error, term()}
  def set_wifi(id, params) do
    with {:ok, wifi} <- Wifi.new(params),
         :ok <- Bastion.Link.command(id, "wifi_config", Wifi.to_args(wifi)) do
      Bastion.Fleet.record_event(id, :command, %{op: "wifi_config", ssid: wifi.ssid})
    end
  end

  defdelegate ssid_max_length(), to: Wifi
end
