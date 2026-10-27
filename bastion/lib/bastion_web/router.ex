defmodule BastionWeb.Router do
  use BastionWeb, :router

  import BastionWeb.AdminAuth,
    only: [fetch_current_admin: 2, require_admin: 2, redirect_if_admin: 2]

  @csp "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " <>
         "img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BastionWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
    plug BastionWeb.Locale
    plug :fetch_current_admin
  end

  pipeline :authenticated do
    plug :require_admin
  end

  pipeline :guest do
    plug :redirect_if_admin
  end

  scope "/", BastionWeb do
    pipe_through [:browser, :guest]

    get "/login", SessionController, :new
    post "/login", SessionController, :create
  end

  scope "/", BastionWeb do
    pipe_through :browser

    post "/locale", LocaleController, :update

    get "/ca.crt", CAController, :show
  end

  scope "/", BastionWeb do
    pipe_through [:browser, :authenticated]

    delete "/logout", SessionController, :delete

    live_session :admin, on_mount: [BastionWeb.Locale, {BastionWeb.AdminAuth, :require_admin}] do
      live "/", DashboardLive, :index
      live "/connect", ConnectLive, :index
      live "/devices/:id", DeviceLive, :console
      live "/devices/:id/settings", DeviceLive, :settings
      live "/devices/:id/info", DeviceLive, :info
      live "/devices/:id/journal", DeviceLive, :journal
    end
  end

  if Application.compile_env(:bastion, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: BastionWeb.Telemetry
    end
  end
end
