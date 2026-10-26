defmodule Bastion.Link.Infrastructure.Listener do
  @moduledoc """
  TLS-слушатель WCS Link для устройств (по умолчанию 7443).

  Только TLS 1.3. Сертификат клиента запрашивается, но не обязателен: без него
  возможна только регистрация. Сертификат, подписанный не нашим CA, обрывает
  рукопожатие. Сертификат сервера — тот же, что у веб-интерфейса (из PKI).
  """

  @doc "Описание дочернего процесса Bandit"
  def child_spec(opts) do
    port = Keyword.fetch!(opts, :port)

    Supervisor.child_spec(
      {Bandit,
       plug: Bastion.Link.Infrastructure.Plug,
       scheme: :https,
       ip: {0, 0, 0, 0, 0, 0, 0, 0},
       port: port,
       startup_log: :info,
       thousand_island_options: [transport_options: ssl_options()]},
      id: __MODULE__
    )
  end

  defp ssl_options do
    Bastion.PKI.server_ssl_options() ++
      [
        versions: [:"tlsv1.3"],
        verify: :verify_peer,
        fail_if_no_peer_cert: false,
        # Быстрое переподключение устройств после обрыва Wi-Fi
        session_tickets: :stateless
      ]
  end
end
