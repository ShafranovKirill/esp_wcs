defmodule Bastion.Link do
  @moduledoc """
  Контекст Link — соединения устройств по WCS Link (`docs/protocol.md`):
  TLS-слушатель на 7443, сеансы регистрации и устройств, статус онлайн.
  """
  use Boundary,
    top_level?: true,
    deps: [Bastion.Events, Bastion.PKI, Bastion.Fleet],
    exports: [Events.PresenceChanged]

  alias Bastion.Link.Application.Presence

  @default_port 7443

  @doc "Процессы контекста — в дерево супервизора после PKI"
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

  @doc "Порт WCS Link для устройств (по умолчанию 7443, `BASTION_LINK_PORT`)"
  @spec port() :: :inet.port_number()
  def port, do: Keyword.get(config(), :port, @default_port)

  @doc "Подписаться на подключения и отключения всех устройств (`:link`)"
  def subscribe, do: Bastion.Events.subscribe(:link)

  @doc "Устройство на связи: показатели или `nil`"
  @spec presence(String.t()) :: Presence.info() | nil
  defdelegate presence(id), to: Presence, as: :get

  @doc "Все устройства на связи: `%{id => показатели}`"
  @spec online() :: %{String.t() => Presence.info()}
  defdelegate online(), to: Presence, as: :all

  defp config, do: Application.get_env(:bastion, __MODULE__, [])
end
