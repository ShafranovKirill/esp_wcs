defmodule BastionWeb.AccessLive do
  use BastionWeb, :live_view

  alias Bastion.{Access, Accounts, Fleet}
  alias Bastion.Fleet.Folder

  @tabs [:grants, :roles, :groups]

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_actor

    if allowed?(actor) do
      if connected?(socket) do
        Accounts.subscribe()
        Fleet.subscribe()
      end

      {:ok,
       socket
       |> assign(
         page_title: gettext("Access"),
         role_form: role_form(nil),
         editing_role: nil,
         group_form: to_form(%{"name" => ""}, as: :group),
         editing_group: nil,
         grant_form: to_form(%{"who" => "", "role_id" => "", "folder_id" => ""}, as: :grant)
       )
       |> load()}
    else
      {:ok, forbidden(socket)}
    end
  end

  defp allowed?(actor),
    do: Access.can?(actor, "users.manage") or Access.can?(actor, "roles.manage")

  defp forbidden(socket),
    do:
      socket
      |> put_flash(:error, BastionWeb.Errors.message(:forbidden))
      |> push_navigate(to: ~p"/")

  @impl true
  def handle_params(_params, _url, socket),
    do: {:noreply, assign(socket, tab: socket.assigns.live_action)}

  defp load(socket) do
    actor = socket.assigns.current_actor
    folders = Fleet.list_folders()

    assign(socket,
      roles: Access.list_roles(),
      groups: Access.list_groups(),
      grants: Access.list_grants(),
      users: Accounts.list_users(),
      folders: folders,
      folders_by_id: Map.new(folders, &{&1.id, &1}),
      manage_users: Access.can?(actor, "users.manage"),
      manage_roles: Access.can?(actor, "roles.manage")
    )
  end

  defp role_form(nil), do: to_form(%{"name" => "", "actions" => []}, as: :role)

  defp role_form(role), do: to_form(%{"name" => role.name, "actions" => role.actions}, as: :role)

  @impl true
  def handle_info({:event, _event}, socket) do
    if allowed?(socket.assigns.current_actor),
      do: {:noreply, load(socket)},
      else: {:noreply, forbidden(socket)}
  end

  @impl true
  def handle_event("new-role", _params, socket),
    do: {:noreply, assign(socket, editing_role: nil, role_form: role_form(nil))}

  def handle_event("edit-role", %{"id" => id}, socket) do
    role = Enum.find(socket.assigns.roles, &(&1.id == id))
    {:noreply, assign(socket, editing_role: role, role_form: role_form(role))}
  end

  def handle_event("save-role", %{"role" => params}, socket) do
    actor = socket.assigns.current_actor
    name = params["name"] || ""
    actions = Enum.reject(params["actions"] || [], &(&1 == ""))

    result =
      case socket.assigns.editing_role do
        nil -> Access.create_role(actor, name, actions)
        role -> Access.update_role(actor, role.id, name, actions)
      end

    case result do
      {:ok, _} ->
        {:noreply, socket |> load() |> push_event("close-dialog", %{id: "role-dialog"})}

      {:error, reason} ->
        form =
          to_form(%{"name" => name, "actions" => actions},
            as: :role,
            errors: [name: {BastionWeb.Errors.message(reason), []}]
          )

        {:noreply, assign(socket, role_form: form)}
    end
  end

  def handle_event("delete-role", %{"id" => id}, socket),
    do:
      result(
        socket,
        Access.delete_role(socket.assigns.current_actor, id),
        gettext("Role deleted")
      )

  def handle_event("new-group", _params, socket),
    do:
      {:noreply,
       assign(socket, editing_group: nil, group_form: to_form(%{"name" => ""}, as: :group))}

  def handle_event("edit-group", %{"id" => id}, socket) do
    group = Enum.find(socket.assigns.groups, &(&1.id == id))

    {:noreply,
     assign(socket,
       editing_group: group,
       group_form: to_form(%{"name" => group.name}, as: :group)
     )}
  end

  def handle_event("save-group", %{"group" => %{"name" => name}}, socket) do
    actor = socket.assigns.current_actor

    result =
      case socket.assigns.editing_group do
        nil -> Access.create_group(actor, name)
        group -> Access.rename_group(actor, group.id, name)
      end

    case result do
      {:ok, _} ->
        {:noreply, socket |> load() |> push_event("close-dialog", %{id: "group-dialog"})}

      {:error, reason} ->
        form =
          to_form(%{"name" => name},
            as: :group,
            errors: [name: {BastionWeb.Errors.message(reason), []}]
          )

        {:noreply, assign(socket, group_form: form)}
    end
  end

  def handle_event("delete-group", %{"id" => id}, socket),
    do:
      result(
        socket,
        Access.delete_group(socket.assigns.current_actor, id),
        gettext("Group deleted")
      )

  def handle_event("add-member", %{"group_id" => group_id, "user_id" => user_id}, socket)
      when user_id != "" do
    result(socket, Access.add_member(socket.assigns.current_actor, group_id, user_id), nil)
  end

  def handle_event("add-member", _params, socket), do: {:noreply, socket}

  def handle_event("remove-member", %{"group" => group_id, "user" => user_id}, socket),
    do: result(socket, Access.remove_member(socket.assigns.current_actor, group_id, user_id), nil)

  def handle_event("grant", %{"grant" => params}, socket) do
    who =
      case String.split(params["who"] || "", ":", parts: 2) do
        ["user", id] -> %{user_id: id}
        ["group", id] -> %{group_id: id}
        _ -> %{}
      end

    attrs = Map.merge(who, %{role_id: params["role_id"], folder_id: params["folder_id"]})

    case Access.grant(socket.assigns.current_actor, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load()
         |> assign(
           grant_form: to_form(%{"who" => "", "role_id" => "", "folder_id" => ""}, as: :grant)
         )
         |> put_flash(:info, gettext("Access granted"))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(grant_form: to_form(params, as: :grant))
         |> put_flash(:error, BastionWeb.Errors.message(reason))}
    end
  end

  def handle_event("revoke-grant", %{"id" => id}, socket),
    do: result(socket, Access.revoke(socket.assigns.current_actor, id), gettext("Access revoked"))

  defp result(socket, result, message) do
    case result do
      ok when ok == :ok or elem(ok, 0) == :ok ->
        socket = load(socket)
        {:noreply, if(message, do: put_flash(socket, :info, message), else: socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, BastionWeb.Errors.message(reason))}
    end
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
      <div>
        <h1 class="text-2xl font-semibold">{gettext("Access")}</h1>
        <p class="text-sm text-base-content/60">
          {gettext(
            "A role is a set of actions. Access is “who + role + folder”: it applies to the folder and everything inside it."
          )}
        </p>
      </div>

      <div role="tablist" class="tabs tabs-border" id="access-tabs">
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

      <section :if={@tab == :grants} id="grants" class="space-y-4">
        <.form
          :if={@manage_users}
          for={@grant_form}
          id="grant-form"
          phx-submit="grant"
          class="flex flex-wrap items-end gap-2 rounded-box border border-base-300 bg-base-100 p-4"
        >
          <div class="min-w-48 flex-1">
            <.input
              field={@grant_form[:who]}
              type="select"
              label={gettext("Who")}
              prompt={gettext("Employee or group")}
              options={who_options(@users, @groups)}
            />
          </div>
          <div class="min-w-40">
            <.input
              field={@grant_form[:role_id]}
              type="select"
              label={gettext("Role")}
              prompt={gettext("Role")}
              options={Enum.map(@roles, &{&1.name, &1.id})}
            />
          </div>
          <div class="min-w-48 flex-1">
            <.input
              field={@grant_form[:folder_id]}
              type="select"
              label={gettext("Where")}
              options={[
                {gettext("Everywhere, including “No folder”"), ""}
                | Enum.map(@folders, &{Folder.full_name(&1, @folders_by_id), &1.id})
              ]}
            />
          </div>
          <button type="submit" class="btn btn-primary mb-2">{gettext("Grant")}</button>
        </.form>

        <div class="rounded-box border border-base-300 bg-base-100">
          <p :if={@grants == []} class="px-4 py-6 text-sm text-base-content/50">
            {gettext("Nothing is granted yet")}
          </p>
          <ul :if={@grants != []} class="divide-y divide-base-300">
            <li
              :for={grant <- @grants}
              id={"grant-#{grant.id}"}
              class="flex flex-wrap items-center gap-x-4 gap-y-1 px-4 py-3 text-sm"
            >
              <span class="flex min-w-40 items-center gap-2 font-medium">
                <.icon
                  name={if(grant.user_id, do: "hero-user", else: "hero-user-group")}
                  class="size-4 text-base-content/60"
                />
                {grantee_name(grant, @users, @groups)}
              </span>
              <span class="badge badge-soft badge-primary">{role_name(grant.role_id, @roles)}</span>
              <span class="flex items-center gap-1 text-base-content/70">
                <.icon
                  name={if(grant.folder_id, do: "hero-folder", else: "hero-globe-alt")}
                  class="size-4"
                />
                {folder_name(grant.folder_id, @folders_by_id)}
              </span>
              <span class="flex-1"></span>
              <button
                :if={@manage_users}
                type="button"
                class="btn btn-ghost btn-xs text-error"
                id={"revoke-grant-#{grant.id}"}
                phx-click="revoke-grant"
                phx-value-id={grant.id}
                data-confirm={gettext("Revoke this access?")}
              >
                <.icon name="hero-x-mark" class="size-4" /> {gettext("Revoke")}
              </button>
            </li>
          </ul>
        </div>
      </section>

      <section :if={@tab == :roles} id="roles" class="space-y-3">
        <div :if={@manage_roles} class="flex justify-end">
          <button
            type="button"
            class="btn btn-sm btn-primary"
            id="new-role"
            phx-click={JS.push("new-role") |> open_dialog("role-dialog")}
          >
            <.icon name="hero-plus" class="size-4" /> {gettext("New role")}
          </button>
        </div>
        <div class="grid gap-3 md:grid-cols-2">
          <div
            :for={role <- @roles}
            id={"role-#{role.id}"}
            class="card border border-base-300 bg-base-100"
          >
            <div class="card-body gap-3 p-4">
              <div class="flex items-center gap-2">
                <h3 class="font-semibold">{role.name}</h3>
                <span :if={role.builtin} class="badge badge-ghost badge-sm">{gettext("built-in")}</span>
                <span class="flex-1"></span>
                <button
                  :if={@manage_roles and role.builtin != "superadmin"}
                  type="button"
                  class="btn btn-ghost btn-xs"
                  id={"edit-role-#{role.id}"}
                  phx-click={
                    JS.push("edit-role", value: %{id: role.id}) |> open_dialog("role-dialog")
                  }
                >
                  <.icon name="hero-pencil" class="size-4" />
                </button>
                <button
                  :if={@manage_roles and is_nil(role.builtin)}
                  type="button"
                  class="btn btn-ghost btn-xs text-error"
                  id={"delete-role-#{role.id}"}
                  phx-click="delete-role"
                  phx-value-id={role.id}
                  data-confirm={
                    gettext("Delete role “%{name}” and every access granted with it?",
                      name: role.name
                    )
                  }
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </div>
              <div class="flex flex-wrap gap-1">
                <span :for={action <- role.actions} class="badge badge-sm badge-outline">
                  {action_label(action)}
                </span>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section :if={@tab == :groups} id="groups" class="space-y-3">
        <div :if={@manage_users} class="flex justify-end">
          <button
            type="button"
            class="btn btn-sm btn-primary"
            id="new-group"
            phx-click={JS.push("new-group") |> open_dialog("group-dialog")}
          >
            <.icon name="hero-plus" class="size-4" /> {gettext("New group")}
          </button>
        </div>
        <p
          :if={@groups == []}
          class="rounded-box border border-dashed border-base-300 px-4 py-6 text-sm text-base-content/50"
        >
          {gettext("No groups yet. A group lets you grant access to a whole team at once.")}
        </p>
        <div
          :for={group <- @groups}
          id={"group-#{group.id}"}
          class="rounded-box border border-base-300 bg-base-100"
        >
          <div class="flex items-center gap-2 px-4 py-3">
            <.icon name="hero-user-group" class="size-5 text-base-content/60" />
            <span class="font-medium">{group.name}</span>
            <span class="badge badge-ghost badge-sm">{length(group.member_ids)}</span>
            <span class="flex-1"></span>
            <button
              :if={@manage_users}
              type="button"
              class="btn btn-ghost btn-xs"
              id={"edit-group-#{group.id}"}
              phx-click={JS.push("edit-group", value: %{id: group.id}) |> open_dialog("group-dialog")}
            >
              <.icon name="hero-pencil" class="size-4" />
            </button>
            <button
              :if={@manage_users}
              type="button"
              class="btn btn-ghost btn-xs text-error"
              id={"delete-group-#{group.id}"}
              phx-click="delete-group"
              phx-value-id={group.id}
              data-confirm={gettext("Delete group “%{name}” and its access?", name: group.name)}
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </div>
          <div class="flex flex-wrap items-center gap-2 border-t border-base-300 px-4 py-3">
            <span
              :for={user <- members(group, @users)}
              class="badge gap-1"
              id={"member-#{group.id}-#{user.id}"}
            >
              {user.username}
              <button
                :if={@manage_users}
                type="button"
                phx-click="remove-member"
                phx-value-group={group.id}
                phx-value-user={user.id}
                aria-label={gettext("Remove from group")}
              >
                <.icon name="hero-x-mark" class="size-3" />
              </button>
            </span>
            <form
              :if={@manage_users}
              phx-change="add-member"
              id={"add-member-#{group.id}"}
              class="contents"
            >
              <input type="hidden" name="group_id" value={group.id} />
              <select name="user_id" class="select select-xs w-44">
                <option value="">{gettext("+ add employee")}</option>
                <option :for={user <- non_members(group, @users)} value={user.id}>
                  {user.username}
                </option>
              </select>
            </form>
          </div>
        </div>
      </section>

      <.dialog
        id="role-dialog"
        title={if(@editing_role, do: gettext("Edit role"), else: gettext("New role"))}
      >
        <.form for={@role_form} id="role-form" phx-submit="save-role">
          <.input field={@role_form[:name]} label={gettext("Name")} maxlength="64" required />
          <input type="hidden" name="role[actions][]" value="" />
          <p class="mt-2 text-sm font-medium">{gettext("In folders")}</p>
          <label
            :for={action <- Access.folder_actions()}
            class="flex cursor-pointer items-center gap-2 py-0.5 text-sm"
          >
            <input
              type="checkbox"
              class="checkbox checkbox-sm"
              name="role[actions][]"
              value={action}
              id={"action-#{String.replace(action, ".", "-")}"}
              checked={action in (@role_form[:actions].value || [])}
            />
            {action_label(action)}
          </label>
          <p class="mt-3 text-sm font-medium">{gettext("Global (only when granted “Everywhere”)")}</p>
          <label
            :for={action <- Access.global_actions()}
            class="flex cursor-pointer items-center gap-2 py-0.5 text-sm"
          >
            <input
              type="checkbox"
              class="checkbox checkbox-sm"
              name="role[actions][]"
              value={action}
              id={"action-#{String.replace(action, ".", "-")}"}
              checked={action in (@role_form[:actions].value || [])}
            />
            {action_label(action)}
          </label>
          <p class="mt-2 text-xs text-base-content/50">
            {gettext(
              "Dependent actions are added automatically: any action includes viewing, console input includes reading."
            )}
          </p>
          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click={close_dialog("role-dialog")}>{gettext(
              "Cancel"
            )}</button>
            <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
          </div>
        </.form>
      </.dialog>

      <.dialog
        id="group-dialog"
        title={if(@editing_group, do: gettext("Rename group"), else: gettext("New group"))}
      >
        <.form for={@group_form} id="group-form" phx-submit="save-group">
          <.input field={@group_form[:name]} label={gettext("Name")} maxlength="64" required />
          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click={close_dialog("group-dialog")}>{gettext(
              "Cancel"
            )}</button>
            <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
          </div>
        </.form>
      </.dialog>
    </Layouts.app>
    """
  end

  defp who_options(users, groups) do
    [
      {gettext("Employees"), Enum.map(users, &{&1.username, "user:#{&1.id}"})},
      {gettext("Groups"), Enum.map(groups, &{&1.name, "group:#{&1.id}"})}
    ]
  end

  defp members(group, users), do: Enum.filter(users, &(&1.id in group.member_ids))
  defp non_members(group, users), do: Enum.reject(users, &(&1.id in group.member_ids))

  defp grantee_name(%{user_id: id}, users, _groups) when is_binary(id),
    do: Enum.find_value(users, "?", &(&1.id == id && &1.username))

  defp grantee_name(%{group_id: id}, _users, groups),
    do: Enum.find_value(groups, "?", &(&1.id == id && &1.name))

  defp role_name(id, roles), do: Enum.find_value(roles, "?", &(&1.id == id && &1.name))

  defp folder_name(nil, _by_id), do: gettext("Everywhere")

  defp folder_name(id, by_id) do
    case by_id[id] do
      nil -> "?"
      folder -> Folder.full_name(folder, by_id)
    end
  end

  def action_label("view"), do: gettext("View devices and journal")
  def action_label("console.read"), do: gettext("Read the console")
  def action_label("console.write"), do: gettext("Type in the console, take it, BREAK")
  def action_label("device.configure"), do: gettext("Name, folders, port settings")
  def action_label("device.wifi"), do: gettext("Change Wi-Fi")
  def action_label("device.reboot"), do: gettext("Reboot")
  def action_label("device.revoke"), do: gettext("Revoke and delete")
  def action_label("folder.manage"), do: gettext("Manage subfolders and maps")
  def action_label("enrollment.approve"), do: gettext("Approve requests")
  def action_label("users.manage"), do: gettext("Manage employees, groups and access")
  def action_label("roles.manage"), do: gettext("Manage roles")
  def action_label("superadmin"), do: gettext("Superadmin — everything")
  def action_label(other), do: other

  defp tab_path(:grants), do: ~p"/access"
  defp tab_path(:roles), do: ~p"/access/roles"
  defp tab_path(:groups), do: ~p"/access/groups"

  defp tab_title(:grants), do: gettext("Who has access")
  defp tab_title(:roles), do: gettext("Roles")
  defp tab_title(:groups), do: gettext("Groups")

  defp tab_icon(:grants), do: "hero-key"
  defp tab_icon(:roles), do: "hero-identification"
  defp tab_icon(:groups), do: "hero-user-group"
end
