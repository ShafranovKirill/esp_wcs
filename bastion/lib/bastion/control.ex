defmodule Bastion.Control do
  use Boundary, top_level?: true, deps: [Bastion.Fleet, Bastion.Link, Bastion.Access]

  alias Bastion.Control.Domain.Wifi

  @spec reboot(Bastion.Access.Actor.t(), String.t()) :: :ok | {:error, term()}
  def reboot(actor, id) do
    with :ok <- Bastion.Fleet.authorize(actor, "device.reboot", id),
         :ok <- Bastion.Link.command(id, "reboot") do
      Bastion.Fleet.record_event(id, :command, %{op: "reboot"}, actor)
    end
  end

  @spec set_wifi(Bastion.Access.Actor.t(), String.t(), map()) :: :ok | {:error, term()}
  def set_wifi(actor, id, params) do
    with :ok <- Bastion.Fleet.authorize(actor, "device.wifi", id),
         {:ok, wifi} <- Wifi.new(params),
         :ok <- Bastion.Link.command(id, "wifi_config", Wifi.to_args(wifi)) do
      Bastion.Fleet.record_event(id, :command, %{op: "wifi_config", ssid: wifi.ssid}, actor)
    end
  end

  defdelegate ssid_max_length(), to: Wifi
end
