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
        <.link navigate={~p"/"} class="brand-link">
          <span class="brand-icon"><.icon name="hero-server-stack" class="size-5" /></span>
          <span>Bastion</span>
        </.link>
        <span class="header-separator" aria-hidden="true"></span>
        <details
          id="navigation-menu"
          class="app-disclosure"
          phx-hook="Disclosure"
          phx-mounted={JS.ignore_attributes(["open"])}
        >
          <summary class="shell-button navigation-button" aria-label={gettext("Navigation")}>
            <.icon name="hero-bars-3" class="size-5" />
            <span class="hidden sm:inline">{gettext("Menu")}</span>
            <.icon name="hero-chevron-down" class="disclosure-chevron size-3" />
          </summary>
          <nav class="shell-popover navigation-popover left-0" aria-label={gettext("Navigation")}>
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

        <details
          :if={@current_user}
          id="profile-menu"
          class="app-disclosure ml-auto"
          phx-hook="Disclosure"
          phx-mounted={JS.ignore_attributes(["open"])}
        >
          <summary class="shell-button profile-button">
            <span class="profile-avatar" aria-hidden="true">{String.upcase(
              String.first(@current_user.username)
            )}</span>
            <span class="profile-name">{@current_user.username}</span>
            <.icon name="hero-chevron-down" class="disclosure-chevron size-3" />
          </summary>
          <div class="shell-popover right-0 profile-popover">
            <div class="profile-identity">
              <span class="profile-avatar profile-avatar-large" aria-hidden="true">{String.upcase(
                String.first(@current_user.username)
              )}</span>
              <div class="min-w-0">
                <p class="identity-caption">{gettext("Signed in as")}</p>
                <p class="identity-name">{@current_user.username}</p>
              </div>
            </div>
            <.link navigate={~p"/account"} id="account-link" class="shell-menu-link">
              <span class="menu-icon"><.icon name="hero-user-circle" class="size-4" /></span><span class="menu-link-label">{gettext(
                "Account"
              )}</span><.icon name="hero-chevron-right" class="menu-link-arrow size-3" />
            </.link>
            <div class="shell-divider"></div>
            <div class="profile-preference">
              <p class="preference-label">{gettext("Language")}</p>
              <.locale_switch locale={@locale} return_to={@current_path} />
            </div>
            <div class="profile-preference">
              <p class="preference-label">{gettext("Appearance")}</p>
              <.theme_toggle />
            </div>
            <div class="shell-divider"></div>
            <.link href={~p"/logout"} method="delete" id="logout" class="shell-menu-link logout-link">
              <span class="menu-icon"><.icon
                name="hero-arrow-right-start-on-rectangle"
                class="size-4"
              /></span><span class="menu-link-label">{gettext("Sign out")}</span>
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
      <span class="menu-icon"><.icon name={@icon} class="size-4" /></span>
      <span class="menu-link-label">{@label}</span>
      <.icon name="hero-chevron-right" class="menu-link-arrow size-3" />
    </.link>
    """
  end

  attr :locale, :string, required: true
  attr :return_to, :string, default: "/"

  def locale_switch(assigns) do
    ~H"""
    <div class="locale-control" id="locale-switch" role="group" aria-label={gettext("Language")}>
      <form
        :for={loc <- BastionWeb.Locale.locales()}
        method="post"
        action={~p"/locale"}
        class="locale-form"
      >
        <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
        <input type="hidden" name="locale" value={loc} />
        <input type="hidden" name="return_to" value={@return_to} />
        <button
          type="submit"
          class={[
            "locale-choice",
            @locale == loc && "locale-choice-active"
          ]}
          aria-pressed={to_string(@locale == loc)}
        >
          <span>{if loc == "ru", do: "Русский", else: "English"}</span>
          <.icon :if={@locale == loc} name="hero-check" class="size-3.5" />
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
      <.theme_toggle compact={true} />
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

  attr :compact, :boolean, default: false

  def theme_toggle(assigns) do
    ~H"""
    <div
      id="theme-control"
      phx-hook="ThemeChoices"
      phx-update="ignore"
      class={["theme-control", @compact && "theme-control-compact"]}
      role="group"
      aria-label={gettext("Appearance")}
    >
      <button
        :for={
          {theme, icon, label} <- [
            {"system", "hero-computer-desktop", gettext("System")},
            {"light", "hero-sun", gettext("Light")},
            {"dark", "hero-moon", gettext("Dark")}
          ]
        }
        type="button"
        class="theme-choice"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
        aria-label={label}
        title={label}
        aria-pressed="false"
      >
        <.icon name={icon} class="size-5" />
        <span class="theme-choice-label">{label}</span>
      </button>
    </div>
    """
  end
end
