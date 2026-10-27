defmodule Bastion.Link do
  use Boundary,
    top_level?: true,
    deps: [Bastion.Events, Bastion.PKI, Bastion.Fleet],
    exports: [Events.PresenceChanged]

  alias Bastion.Link.Application.Presence

  @default_port 7443

  def child_spec(_opts) do
    config = config()

    %{
      id: __MODULE__,
      start:
        {Bastion.Link.Infrastructure.Supervisor, :start_link,
         [[port: port(), listen: Keyword.get(config, :listen, true)]]},
      type: :supervisor
    }
  end

  @spec port() :: :inet.port_number()
  def port, do: Keyword.get(config(), :port, @default_port)

  def subscribe, do: Bastion.Events.subscribe(:link)

  @spec presence(String.t()) :: Presence.info() | nil
  defdelegate presence(id), to: Presence, as: :get

  @spec online() :: %{String.t() => Presence.info()}
  defdelegate online(), to: Presence, as: :all

  defp config, do: Application.get_env(:bastion, __MODULE__, [])
end
