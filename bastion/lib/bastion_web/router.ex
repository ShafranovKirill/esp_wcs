defmodule BastionWeb.Router do
  use BastionWeb, :router

  import BastionWeb.UserAuth,
    only: [fetch_current_user: 2, require_user: 2, redirect_if_user: 2]

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
    plug :fetch_current_user
  end

  pipeline :authenticated do
    plug :require_user
  end

  pipeline :guest do
    plug :redirect_if_user
  end

  scope "/", BastionWeb do
    pipe_through [:browser, :guest]

    get "/login", SessionController, :new
    post "/login", SessionController, :create
  end

  scope "/", BastionWeb do
    pipe_through :browser

    post "/locale", LocaleController, :update

    get "/ca", CAController, :page
    get "/ca.crt", CAController, :show
  end

  scope "/", BastionWeb do
    pipe_through [:browser, :authenticated]

    delete "/logout", SessionController, :delete

    live_session :staff, on_mount: [BastionWeb.Locale, {BastionWeb.UserAuth, :require_user}] do
      live "/", DashboardLive, :index
      live "/connect", ConnectLive, :index
      live "/devices/:id", DeviceLive, :console
      live "/devices/:id/settings", DeviceLive, :settings
      live "/devices/:id/info", DeviceLive, :info
      live "/devices/:id/journal", DeviceLive, :journal
      live "/users", UsersLive, :staff
      live "/users/journal", UsersLive, :journal
      live "/account", AccountLive, :index
      live "/access", AccessLive, :grants
      live "/access/roles", AccessLive, :roles
      live "/access/groups", AccessLive, :groups
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
