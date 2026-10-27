defmodule BastionWeb do
  use Boundary,
    deps: [
      Bastion.Events,
      Bastion.PKI,
      Bastion.Accounts,
      Bastion.Fleet,
      Bastion.Link,
      Bastion.Console,
      Bastion.Control
    ],
    exports: [Endpoint, Telemetry, TLS]

  def static_paths, do: ~w(assets fonts images js favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: BastionWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      use Gettext, backend: BastionWeb.Gettext

      import Phoenix.HTML
      import BastionWeb.CoreComponents
      import BastionWeb.UIComponents

      alias Phoenix.LiveView.JS
      alias BastionWeb.Layouts

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: BastionWeb.Endpoint,
        router: BastionWeb.Router,
        statics: BastionWeb.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
