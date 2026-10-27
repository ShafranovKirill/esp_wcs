defmodule Bastion.Application do
  use Boundary,
    top_level?: true,
    deps: [
      Bastion.Repo,
      Bastion.PKI,
      Bastion.Accounts,
      Bastion.Link,
      Bastion.Console,
      Bastion.Discovery,
      BastionWeb
    ]

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BastionWeb.Telemetry,
      Bastion.Repo,
      {Phoenix.PubSub, name: Bastion.PubSub},
      Bastion.PKI,
      Bastion.Accounts,
      Bastion.Link,
      Bastion.Console,
      Bastion.Discovery,
      BastionWeb.TLS.endpoint_child_spec(),
      BastionWeb.TLS
    ]

    opts = [strategy: :one_for_one, name: Bastion.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    BastionWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
