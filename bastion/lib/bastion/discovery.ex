defmodule Bastion.Discovery do
  use Boundary, top_level?: true, deps: []

  alias Bastion.Discovery.Infrastructure.{Responder, Supervisor}

  @name "bastion.local"
  @modes [:auto, :avahi, :dns_sd, :builtin, :off]

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Supervisor, :start_link, [[name: @name, mode: mode(), port: https_port()]]},
      type: :supervisor
    }
  end

  @spec name() :: String.t()
  def name, do: @name

  @spec modes() :: [atom()]
  def modes, do: @modes

  @spec method() :: :avahi | :dns_sd | :builtin | :off
  def method, do: Supervisor.method()

  @spec answer(binary(), [:inet.ip4_address()]) :: Responder.reply()
  defdelegate answer(packet, addresses), to: Responder

  defp mode do
    mode = config() |> Keyword.get(:mode, :auto) |> to_string()
    Enum.find(@modes, :auto, &(Atom.to_string(&1) == mode))
  end

  defp https_port, do: Keyword.get(config(), :https_port, 443)
  defp config, do: Application.get_env(:bastion, __MODULE__, [])
end
