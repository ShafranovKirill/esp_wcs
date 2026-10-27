defmodule Bastion.Link.Infrastructure.Listener do
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
        ciphers: ciphers(),
        verify: :verify_peer,
        fail_if_no_peer_cert: false,
        session_tickets: :stateless
      ]
  end

  defp ciphers do
    :ssl.filter_cipher_suites(:ssl.cipher_suites(:all, :"tlsv1.3"),
      cipher: &(&1 in [:aes_128_gcm, :chacha20_poly1305])
    )
  end
end
