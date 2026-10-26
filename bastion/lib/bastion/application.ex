defmodule Bastion.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Boundary, top_level?: true, deps: [Bastion.Repo, Bastion.PKI, BastionWeb]
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BastionWeb.Telemetry,
      Bastion.Repo,
      {Phoenix.PubSub, name: Bastion.PubSub},
      # Центр сертификации — до веб-сервера: тот берёт у него сертификат
      Bastion.PKI,
      # Веб-сервер с сертификатом из PKI и его перезапуск при перевыпуске
      BastionWeb.TLS.endpoint_child_spec(),
      BastionWeb.TLS
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Bastion.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BastionWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
