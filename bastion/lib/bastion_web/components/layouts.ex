defmodule BastionWeb.Layouts do
  use BastionWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_user, :map, default: nil, doc: "вошедший сотрудник"
  attr :current_actor, :any, default: nil, doc: "права вошедшего сотрудника"
  attr :locale, :string, default: "ru"
  attr :current_path, :string, default: "/"
  attr :map_mode, :boolean, default: false
  attr :wide, :boolean, default: false
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header :if={!@map_mode} class="app-header">
      <div class="app-header-inner">
        <details
          id="navigation-menu"
          class="app-disclosure"
          phx-hook="Disclosure"
          phx-mounted={JS.ignore_attributes(["open"])}
        >
          <summary class="shell-button" aria-label={gettext("Navigation")}>
            <.icon name="hero-bars-3" class="size-5" />
            <span class="hidden sm:inline">{gettext("Menu")}</span>
            <.icon name="hero-chevron-down" class="disclosure-chevron size-3" />
          </summary>
          <nav class="shell-popover left-0" aria-label={gettext("Navigation")}>
            <p class="shell-menu-label">{gettext("Workspace")}</p>
            <.nav_link
              to={~p"/"}
              icon="hero-cpu-chip"
              label={gettext("Devices")}
              active={
                @current_path == "/" or String.starts_with?(@current_path, "/?") or
                  String.starts_with?(@current_path, "/devices")
              }
            />
            <div :if={can?(@current_actor, "users.manage") or can?(@current_actor, "roles.manage")}>
              <p class="shell-menu-label mt-3">{gettext("Administration")}</p>
              <.nav_link
                :if={can?(@current_actor, "users.manage")}
                to={~p"/users"}
                icon="hero-users"
                label={gettext("Staff")}
                active={String.starts_with?(@current_path, "/users")}
              />
              <.nav_link
                to={~p"/access"}
                icon="hero-shield-check"
                label={gettext("Access")}
                active={String.starts_with?(@current_path, "/access")}
              />
            </div>
            <div class="shell-divider"></div>
            <.nav_link
              to={~p"/connect"}
              icon="hero-question-mark-circle"
              label={gettext("Help")}
              active={@current_path == "/connect"}
            />
          </nav>
        </details>
        <.link navigate={~p"/"} class="brand-link">
          <span class="brand-icon"><.icon name="hero-server-stack" class="size-5" /></span>
          <span>Bastion</span>
        </.link>
        <details
          :if={@current_user}
          id="profile-menu"
          class="app-disclosure ml-auto"
          phx-hook="Disclosure"
          phx-mounted={JS.ignore_attributes(["open"])}
        >
          <summary class="shell-button profile-button">
            <.icon name="hero-user-circle" class="size-5 text-primary" />
            <span class="max-w-32 truncate">{@current_user.username}</span>
            <.icon name="hero-chevron-down" class="disclosure-chevron size-3" />
          </summary>
          <div class="shell-popover right-0 profile-popover">
            <p class="shell-menu-label">{gettext("Signed in as")}</p>
            <p class="px-3 pb-3 font-semibold break-all">{@current_user.username}</p>
            <.link navigate={~p"/account"} id="account-link" class="shell-menu-link">
              <.icon name="hero-user-circle" class="size-4" />{gettext("Account")}
            </.link>
            <div class="shell-divider"></div>
            <div class="space-y-2 px-3 py-2">
              <p class="text-xs font-medium text-base-content/60">{gettext("Language")}</p>
              <.locale_switch locale={@locale} return_to={@current_path} />
            </div>
            <div class="space-y-2 px-3 py-2">
              <p class="text-xs font-medium text-base-content/60">{gettext("Appearance")}</p>
              <.theme_toggle />
            </div>
            <div class="shell-divider"></div>
            <.link href={~p"/logout"} method="delete" id="logout" class="shell-menu-link">
              <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />{gettext("Sign out")}
            </.link>
          </div>
        </details>
      </div>
    </header>

    <main class={if @map_mode, do: "h-dvh overflow-hidden", else: "app-main"}>
      <div class={["mx-auto min-w-0 space-y-6", !@wide && "max-w-7xl"]}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  defp can?(nil, _action), do: false
  defp can?(actor, action), do: Bastion.Access.can?(actor, action)

  attr :to, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@to}
      title={@label}
      aria-label={@label}
      aria-current={@active && "page"}
      class={["shell-menu-link", @active && "shell-menu-link-active"]}
    >
      <.icon name={@icon} class="size-4" />
      <span>{@label}</span>
    </.link>
    """
  end

  attr :locale, :string, required: true
  attr :return_to, :string, default: "/"

  def locale_switch(assigns) do
    ~H"""
    <div class="join" id="locale-switch">
      <form
        :for={loc <- BastionWeb.Locale.locales()}
        method="post"
        action={~p"/locale"}
        class="join-item"
      >
        <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
        <input type="hidden" name="locale" value={loc} />
        <input type="hidden" name="return_to" value={@return_to} />
        <button
          type="submit"
          class={[
            "btn btn-xs join-item uppercase",
            if(@locale == loc, do: "btn-active", else: "btn-ghost")
          ]}
          aria-pressed={to_string(@locale == loc)}
        >
          {loc}
        </button>
      </form>
    </div>
    """
  end

  attr :flash, :map, required: true
  attr :locale, :string, default: "ru"
  attr :current_path, :string, default: "/login"
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <main class="flex min-h-screen items-center justify-center bg-base-200 px-4">
      {render_slot(@inner_block)}
    </main>
    <div class="fixed right-4 top-4 flex items-center gap-2">
      <.locale_switch locale={@locale} return_to={@current_path} />
      <.theme_toggle />
    </div>
    <.flash_group flash={@flash} />
    """
  end

  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("Connection to the bastion lost")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label={gettext("System theme")}
        title={gettext("System theme")}
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label={gettext("Light theme")}
        title={gettext("Light theme")}
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label={gettext("Dark theme")}
        title={gettext("Dark theme")}
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
