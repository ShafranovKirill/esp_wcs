defmodule BastionWeb.Layouts do
  use BastionWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_user, :map, default: nil, doc: "вошедший сотрудник"
  attr :current_actor, :any, default: nil, doc: "права вошедшего сотрудника"
  attr :locale, :string, default: "ru"
  attr :current_path, :string, default: "/"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="sticky top-0 z-30 border-b border-base-300 bg-base-100/90 backdrop-blur">
      <div class="mx-auto flex h-14 max-w-6xl items-center gap-4 px-4 sm:px-6 lg:px-8">
        <.link navigate={~p"/"} class="flex items-center gap-2 font-semibold">
          <span class="grid size-8 place-items-center rounded-lg bg-primary text-primary-content">
            <.icon name="hero-server-stack" class="size-5" />
          </span>
          <span class="hidden sm:inline">{gettext("ESP WCS Bastion")}</span>
        </.link>

        <nav class="flex items-center gap-1 text-sm">
          <.nav_link
            to={~p"/"}
            icon="hero-cpu-chip"
            label={gettext("Devices")}
            active={@current_path == "/" or String.starts_with?(@current_path, "/devices")}
          />
          <.nav_link
            to={~p"/connect"}
            icon="hero-plus-circle"
            label={gettext("How to connect")}
            active={@current_path == "/connect"}
          />
          <.nav_link
            :if={can?(@current_actor, "users.manage")}
            to={~p"/users"}
            icon="hero-users"
            label={gettext("Staff")}
            active={String.starts_with?(@current_path, "/users")}
          />
          <.nav_link
            :if={can?(@current_actor, "users.manage") or can?(@current_actor, "roles.manage")}
            to={~p"/access"}
            icon="hero-shield-check"
            label={gettext("Access")}
            active={String.starts_with?(@current_path, "/access")}
          />
        </nav>

        <div class="ml-auto flex items-center gap-2">
          <.locale_switch locale={@locale} return_to={@current_path} />
          <.theme_toggle />
          <.link
            :if={@current_user}
            navigate={~p"/account"}
            id="account-link"
            class="btn btn-ghost btn-sm"
            title={gettext("Account")}
          >
            <.icon name="hero-user-circle" class="size-4" />
            <span class="hidden md:inline">{@current_user.username}</span>
          </.link>
          <.link
            :if={@current_user}
            href={~p"/logout"}
            method="delete"
            id="logout"
            class="btn btn-ghost btn-sm"
            title={gettext("Sign out")}
          >
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
            <span class="hidden sm:inline">{gettext("Sign out")}</span>
          </.link>
        </div>
      </div>
    </header>

    <main class="px-4 py-6 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-6xl space-y-6">
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
      class={[
        "flex items-center gap-1.5 whitespace-nowrap rounded-lg px-2.5 py-1.5 transition-colors",
        if(@active, do: "bg-base-200 font-medium", else: "text-base-content/70 hover:bg-base-200/60")
      ]}
    >
      <.icon name={@icon} class="size-4 md:hidden" />
      <span class="hidden md:inline">{@label}</span>
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
        title={gettext("We can't find the internet")}
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
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
