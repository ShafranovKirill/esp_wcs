defmodule BastionWeb.UsersLive do
  use BastionWeb, :live_view

  alias Bastion.Accounts
  alias Bastion.Accounts.User

  @tabs [:staff, :journal]

  @impl true
  def mount(_params, _session, socket) do
    if Bastion.Access.can?(socket.assigns.current_actor, "users.manage"),
      do: mount_staff(socket),
      else: {:ok, forbidden(socket)}
  end

  defp mount_staff(socket) do
    if connected?(socket), do: Accounts.subscribe()

    {:ok,
     socket
     |> assign(
       page_title: gettext("Staff"),
       user_form: to_form(%{"username" => ""}, as: :user),
       issued: nil
     )
     |> load()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    tab = socket.assigns.live_action
    {:noreply, socket |> assign(tab: tab) |> load()}
  end

  defp load(socket) do
    socket
    |> assign(users: Accounts.list_users())
    |> then(fn s ->
      if s.assigns[:tab] == :journal do
        folders = Bastion.Fleet.list_folders()
        by_id = Map.new(folders, &{&1.id, &1})

        assign(s,
          events: Accounts.list_access_events(),
          folder_names: Map.new(folders, &{&1.id, Bastion.Fleet.Folder.full_name(&1, by_id)})
        )
      else
        assign(s, events: [], folder_names: %{})
      end
    end)
  end

  @impl true
  def handle_info({:event, _event}, socket) do
    if Bastion.Access.can?(socket.assigns.current_actor, "users.manage"),
      do: {:noreply, load(socket)},
      else: {:noreply, forbidden(socket)}
  end

  defp forbidden(socket),
    do:
      socket
      |> put_flash(:error, BastionWeb.Errors.message(:forbidden))
      |> push_navigate(to: ~p"/")

  @impl true
  def handle_event("new-user", _params, socket) do
    {:noreply, assign(socket, user_form: to_form(%{"username" => ""}, as: :user), issued: nil)}
  end

  def handle_event("create-user", %{"user" => %{"username" => username}}, socket) do
    case Accounts.create_user(socket.assigns.current_actor, username) do
      {:ok, user, password} ->
        {:noreply,
         socket
         |> push_event("close-dialog", %{id: "user-dialog"})
         |> show_password(user, password, :created)}

      {:error, reason} ->
        form =
          to_form(%{"username" => username},
            as: :user,
            errors: [username: {BastionWeb.Errors.message(reason), []}]
          )

        {:noreply, assign(socket, user_form: form)}
    end
  end

  def handle_event("reset-password", %{"id" => id}, socket) do
    case Accounts.reset_password(socket.assigns.current_actor, id) do
      {:ok, user, password} -> {:noreply, show_password(socket, user, password, :reset)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, BastionWeb.Errors.message(reason))}
    end
  end

  def handle_event("block", %{"id" => id}, socket) do
    case Accounts.block(socket.assigns.current_actor, id) do
      {:ok, user} ->
        {:noreply, put_flash(socket, :info, gettext("%{name} blocked", name: user.username))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, BastionWeb.Errors.message(reason))}
    end
  end

  def handle_event("unblock", %{"id" => id}, socket) do
    case Accounts.unblock(socket.assigns.current_actor, id) do
      {:ok, user} ->
        {:noreply, put_flash(socket, :info, gettext("%{name} unblocked", name: user.username))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, BastionWeb.Errors.message(reason))}
    end
  end

  def handle_event("password-seen", _params, socket) do
    {:noreply,
     socket |> assign(issued: nil) |> push_event("close-dialog", %{id: "password-dialog"})}
  end

  defp show_password(socket, user, password, kind) do
    socket
    |> assign(issued: %{username: user.username, password: password, kind: kind})
    |> push_event("open-dialog", %{id: "password-dialog"})
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_actor={@current_actor}
      locale={@locale}
      current_path={@current_path}
    >
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold">{gettext("Staff")}</h1>
          <p class="text-sm text-base-content/60">
            {ngettext("%{count} account", "%{count} accounts", length(@users))}
          </p>
        </div>
        <button
          type="button"
          class="btn btn-sm btn-primary"
          id="new-user"
          phx-click={JS.push("new-user") |> open_dialog("user-dialog")}
        >
          <.icon name="hero-user-plus" class="size-4" /> {gettext("New employee")}
        </button>
      </div>

      <div role="tablist" class="tabs tabs-border" id="staff-tabs">
        <.link
          :for={tab <- @tabs}
          patch={tab_path(tab)}
          role="tab"
          id={"tab-#{tab}"}
          class={["tab gap-2", @tab == tab && "tab-active"]}
          aria-selected={to_string(@tab == tab)}
        >
          <.icon name={tab_icon(tab)} class="size-4" /> {tab_title(tab)}
        </.link>
      </div>

      <section
        :if={@tab == :staff}
        id="users"
        class="rounded-box border border-base-300 bg-base-100"
      >
        <ul class="divide-y divide-base-300">
          <li
            :for={user <- @users}
            id={"user-#{user.id}"}
            class="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3"
          >
            <span class="grid size-8 place-items-center rounded-full bg-base-200">
              <.icon name="hero-user" class="size-4" />
            </span>
            <span class="min-w-40 font-medium">
              {user.username}
              <span :if={user.id == @current_user.id} class="badge badge-ghost badge-sm ml-1">
                {gettext("you")}
              </span>
            </span>
            <span :if={User.blocked?(user)} class="badge badge-error badge-soft badge-sm">
              {gettext("Blocked")}
            </span>
            <span
              :if={!User.blocked?(user) and is_nil(user.password_changed_at)}
              class="badge badge-warning badge-soft badge-sm"
              title={gettext("The employee has not changed the issued password yet")}
            >
              {gettext("Issued password")}
            </span>
            <span class="flex-1"></span>
            <span class="text-xs text-base-content/50">
              {gettext("since")} <.time at={user.inserted_at} id={"user-since-#{user.id}"} />
            </span>
            <div :if={user.id != @current_user.id} class="flex gap-1">
              <button
                type="button"
                class="btn btn-ghost btn-xs"
                id={"reset-#{user.id}"}
                phx-click="reset-password"
                phx-value-id={user.id}
                data-confirm={
                  gettext(
                    "Reset the password of %{name}? Their sessions will be closed and a new password will be shown once.",
                    name: user.username
                  )
                }
              >
                <.icon name="hero-key" class="size-4" /> {gettext("Reset password")}
              </button>
              <button
                :if={!User.blocked?(user)}
                type="button"
                class="btn btn-ghost btn-xs text-error"
                id={"block-#{user.id}"}
                phx-click="block"
                phx-value-id={user.id}
                data-confirm={
                  gettext("Block %{name}? Their sessions will be closed immediately.",
                    name: user.username
                  )
                }
              >
                <.icon name="hero-no-symbol" class="size-4" /> {gettext("Block")}
              </button>
              <button
                :if={User.blocked?(user)}
                type="button"
                class="btn btn-ghost btn-xs"
                id={"unblock-#{user.id}"}
                phx-click="unblock"
                phx-value-id={user.id}
              >
                <.icon name="hero-check-circle" class="size-4" /> {gettext("Unblock")}
              </button>
            </div>
          </li>
        </ul>
      </section>

      <section
        :if={@tab == :journal}
        id="access-journal"
        class="rounded-box border border-base-300 bg-base-100"
      >
        <p :if={@events == []} class="px-4 py-6 text-sm text-base-content/50">
          {gettext("No events yet")}
        </p>
        <ol :if={@events != []} class="divide-y divide-base-300">
          <li
            :for={event <- @events}
            id={"access-#{event.id}"}
            class="flex items-start gap-3 px-4 py-3"
          >
            <span class="mt-0.5 grid size-7 shrink-0 place-items-center rounded-full bg-base-200">
              <.icon name={event_icon(event.type)} class="size-4" />
            </span>
            <p class="flex-1 text-sm">
              {event_text(event, @folder_names)}
              <span :if={event.remote_ip} class="text-base-content/50">· {event.remote_ip}</span>
            </p>
            <span class="shrink-0 text-xs text-base-content/50"><.time
              at={event.at}
              id={"access-at-#{event.id}"}
            /></span>
          </li>
        </ol>
      </section>

      <.dialog id="user-dialog" title={gettext("New employee")}>
        <.form for={@user_form} id="user-form" phx-submit="create-user">
          <.input
            field={@user_form[:username]}
            label={gettext("Username")}
            maxlength="64"
            required
            autocomplete="off"
          />
          <p class="text-sm text-base-content/60">
            {gettext(
              "A password is generated and shown once. The employee changes it on the account page."
            )}
          </p>
          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click={close_dialog("user-dialog")}>{gettext(
              "Cancel"
            )}</button>
            <button type="submit" class="btn btn-primary">{gettext("Create")}</button>
          </div>
        </.form>
      </.dialog>

      <.dialog id="password-dialog" title={gettext("Password")}>
        <div :if={@issued} class="space-y-3 text-sm">
          <p>
            {if(@issued.kind == :created,
              do: gettext("Account %{name} created. Its password:", name: @issued.username),
              else: gettext("New password of %{name}:", name: @issued.username)
            )}
          </p>
          <div class="flex flex-wrap items-center justify-center gap-2 py-2">
            <.code code={@issued.password} size="lg" id="issued-password" />
            <.copy_button id="copy-password" text={@issued.password} />
          </div>
          <p class="text-base-content/60">
            {gettext(
              "The password is shown only now. Pass it to the employee — they should change it after signing in."
            )}
          </p>
        </div>
        <:actions>
          <button type="button" class="btn btn-primary" phx-click="password-seen" id="password-seen">
            {gettext("Done")}
          </button>
        </:actions>
      </.dialog>
    </Layouts.app>
    """
  end

  defp tab_path(:staff), do: ~p"/users"
  defp tab_path(:journal), do: ~p"/users/journal"

  defp tab_title(:staff), do: gettext("Employees")
  defp tab_title(:journal), do: gettext("Access journal")

  defp tab_icon(:staff), do: "hero-users"
  defp tab_icon(:journal), do: "hero-clipboard-document-list"

  defp event_icon(:login), do: "hero-arrow-right-end-on-rectangle"
  defp event_icon(:login_failed), do: "hero-exclamation-triangle"
  defp event_icon(:logout), do: "hero-arrow-right-start-on-rectangle"
  defp event_icon(:user_created), do: "hero-user-plus"
  defp event_icon(:password_changed), do: "hero-key"
  defp event_icon(:password_reset), do: "hero-key"
  defp event_icon(:blocked), do: "hero-no-symbol"
  defp event_icon(:unblocked), do: "hero-check-circle"
  defp event_icon(type) when type in [:role_created, :role_updated], do: "hero-identification"
  defp event_icon(:role_deleted), do: "hero-identification"
  defp event_icon(type) when type in [:group_created, :group_renamed], do: "hero-user-group"
  defp event_icon(:group_deleted), do: "hero-user-group"
  defp event_icon(:member_added), do: "hero-user-plus"
  defp event_icon(:member_removed), do: "hero-user-minus"
  defp event_icon(:access_granted), do: "hero-shield-check"
  defp event_icon(:access_revoked), do: "hero-shield-exclamation"

  defp event_text(%{type: :role_created} = e, _folders),
    do: gettext("%{actor} created role %{role}", actor: actor(e), role: e.data["role"])

  defp event_text(%{type: :role_updated} = e, _folders),
    do: gettext("%{actor} changed role %{role}", actor: actor(e), role: e.data["role"])

  defp event_text(%{type: :role_deleted} = e, _folders),
    do: gettext("%{actor} deleted role %{role}", actor: actor(e), role: e.data["role"])

  defp event_text(%{type: :group_created} = e, _folders),
    do: gettext("%{actor} created group %{group}", actor: actor(e), group: e.data["group"])

  defp event_text(%{type: :group_renamed} = e, _folders),
    do:
      gettext("%{actor} renamed group %{from} to %{group}",
        actor: actor(e),
        from: e.data["from"],
        group: e.data["group"]
      )

  defp event_text(%{type: :group_deleted} = e, _folders),
    do: gettext("%{actor} deleted group %{group}", actor: actor(e), group: e.data["group"])

  defp event_text(%{type: :member_added} = e, _folders),
    do:
      gettext("%{actor} added %{name} to group %{group}",
        actor: actor(e),
        name: subject(e),
        group: e.data["group"]
      )

  defp event_text(%{type: :member_removed} = e, _folders),
    do:
      gettext("%{actor} removed %{name} from group %{group}",
        actor: actor(e),
        name: subject(e),
        group: e.data["group"]
      )

  defp event_text(%{type: :access_granted} = e, folders),
    do:
      gettext("%{actor} granted %{role} to %{name} in %{folder}",
        actor: actor(e),
        role: e.data["role"],
        name: grantee(e),
        folder: folder(e, folders)
      )

  defp event_text(%{type: :access_revoked} = e, folders),
    do:
      gettext("%{actor} revoked %{role} from %{name} in %{folder}",
        actor: actor(e),
        role: e.data["role"],
        name: grantee(e),
        folder: folder(e, folders)
      )

  defp event_text(event, _folders), do: event_text(event)

  defp event_text(%{type: :login, username: name}), do: gettext("%{name} signed in", name: name)

  defp event_text(%{type: :login_failed, username: name, data: %{"reason" => "blocked"}}),
    do: gettext("Sign-in of blocked %{name} refused", name: name)

  defp event_text(%{type: :login_failed, username: name}),
    do: gettext("Failed sign-in as %{name}", name: name)

  defp event_text(%{type: :logout, username: name}),
    do: gettext("%{name} signed out", name: name)

  defp event_text(%{type: :user_created} = e),
    do: gettext("%{actor} created %{name}", actor: actor(e), name: e.username)

  defp event_text(%{type: :password_changed, username: name}),
    do: gettext("%{name} changed their password", name: name)

  defp event_text(%{type: :password_reset} = e),
    do: gettext("%{actor} reset the password of %{name}", actor: actor(e), name: e.username)

  defp event_text(%{type: :blocked} = e),
    do: gettext("%{actor} blocked %{name}", actor: actor(e), name: e.username)

  defp event_text(%{type: :unblocked} = e),
    do: gettext("%{actor} unblocked %{name}", actor: actor(e), name: e.username)

  defp subject(%{username: nil}), do: gettext("deleted account")
  defp subject(%{username: name}), do: name

  defp grantee(%{data: %{"group" => group}}), do: gettext("group %{group}", group: group)
  defp grantee(event), do: subject(event)

  defp folder(%{data: %{"folder_id" => id}}, folders),
    do: Map.get(folders, id, gettext("a deleted folder"))

  defp folder(_event, _folders), do: gettext("all folders")

  defp actor(%{actor: nil}), do: gettext("deleted account")
  defp actor(%{actor: name}), do: name
end
