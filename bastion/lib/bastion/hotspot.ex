defmodule Bastion.Hotspot do
  use Boundary, top_level?: true, deps: [Bastion.Access, Bastion.Link]

  alias Bastion.Hotspot.Infrastructure.NetworkManager

  def enabled?, do: Application.get_env(:bastion, __MODULE__, [])[:enabled] == true

  def details(actor) do
    if Bastion.Access.Actor.superadmin?(actor) && enabled?() do
      config = Application.get_env(:bastion, __MODULE__, [])

      %{
        ssid: config[:ssid],
        password: config[:password],
        address: "10.42.0.1:#{Bastion.Link.port()}"
      }
    end
  end

  def change(actor, action) when action in [:start, :stop] do
    cond do
      not Bastion.Access.Actor.superadmin?(actor) -> {:error, :forbidden}
      not enabled?() -> {:error, :disabled}
      true -> NetworkManager.change(action)
    end
  end
end
