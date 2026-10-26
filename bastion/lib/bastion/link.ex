defmodule Bastion.Link do
  @moduledoc """
  Контекст Link — соединения устройств по WCS Link (`docs/protocol.md`).

  Пока только настройки: слушатель для устройств, процессы сеансов и
  онлайн-статус появятся следующим шагом этапа 2.
  """
  use Boundary, top_level?: true, deps: []

  @default_port 7443

  @doc "Порт WCS Link для устройств (по умолчанию 7443, `BASTION_LINK_PORT`)"
  @spec port() :: :inet.port_number()
  def port, do: Application.get_env(:bastion, __MODULE__, []) |> Keyword.get(:port, @default_port)
end
