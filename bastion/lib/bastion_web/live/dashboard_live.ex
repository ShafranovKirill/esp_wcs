defmodule BastionWeb.DashboardLive do
  use BastionWeb, :live_view

  alias Bastion.Fleet
  alias Bastion.Fleet.Folder

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Fleet.subscribe()
      Bastion.Link.subscribe()
    end

    socket =
      socket
      |> assign(
        page_title: gettext("Devices"),
        bastion_code: Bastion.PKI.bastion_code(),
        query: "",
        approving: nil,
        folder_form: to_form(%{"name" => ""}, as: :folder),
        folder_mode: {:new, nil},
        move_form: to_form(%{"parent_id" => ""}, as: :move),
        moving_folder: nil,
        collapsed: MapSet.new()
      )
      |> load()

    {:ok, socket}
  end

  defp load(socket) do
    actor = socket.assigns.current_actor
    overview = Fleet.overview(actor)

    assign(socket,
      overview: overview,
      tree: Folder.tree(overview.folders),
      folders_by_id: Map.new(overview.folders, &{&1.id, &1}),
      can_approve: Bastion.Access.can?(actor, "enrollment.approve"),
      can_root: Fleet.can_folder?(actor, "folder.manage", nil),
      total: overview.total,
      online: Bastion.Link.online()
    )
  end

  @impl true
  def handle_info({:event, %Bastion.Link.Events.PresenceChanged{}}, socket),
    do: {:noreply, assign(socket, online: Bastion.Link.online())}

  def handle_info({:event, _event}, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("search", %{"q" => query}, socket),
    do: {:noreply, assign(socket, query: String.trim(query))}

  def handle_event("confirm-approve", %{"id" => id}, socket) do
    device = Enum.find(socket.assigns.overview.requests, &(&1.id == id))
    {:noreply, assign(socket, approving: device)}
  end

  def handle_event("approve", %{"id" => id, "code" => code}, socket) do
    socket = push_event(socket, "close-dialog", %{id: "approve-dialog"})

    case Fleet.approve(socket.assigns.current_actor, id, code) do
      {:ok, device} ->
        {:noreply,
         socket
         |> assign(approving: nil)
         |> put_flash(:info, gettext("%{name} approved", name: device.name))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, BastionWeb.Errors.message(reason))}
    end
  end

  def handle_event("reject", %{"id" => id}, socket) do
    case Fleet.reject(socket.assigns.current_actor, id) do
      {:ok, _} -> {:noreply, put_flash(socket, :info, gettext("Request rejected"))}
      {:error, reason} -> {:noreply, put_flash(socket, :error, BastionWeb.Errors.message(reason))}
    end
  end

  def handle_event("toggle-folder", %{"id" => id}, socket) do
    collapsed = socket.assigns.collapsed

    collapsed =
      if MapSet.member?(collapsed, id),
        do: MapSet.delete(collapsed, id),
        else: MapSet.put(collapsed, id)

    {:noreply, assign(socket, collapsed: collapsed)}
  end

  def handle_event("new-folder", params, socket) do
    parent = params["parent"] && socket.assigns.folders_by_id[params["parent"]]

    {:noreply,
     assign(socket,
       folder_mode: {:new, parent},
       folder_form: to_form(%{"name" => ""}, as: :folder)
     )}
  end

  def handle_event("edit-folder", %{"id" => id}, socket) do
    folder = socket.assigns.folders_by_id[id]

    {:noreply,
     assign(socket,
       folder_mode: {:rename, folder},
       folder_form: to_form(%{"name" => folder.name}, as: :folder)
     )}
  end

  def handle_event("save-folder", %{"folder" => %{"name" => name}}, socket) do
    result =
      case socket.assigns.folder_mode do
        {:new, parent} ->
          Fleet.create_folder(socket.assigns.current_actor, name, parent && parent.id)

        {:rename, folder} ->
          Fleet.rename_folder(socket.assigns.current_actor, folder.id, name)
      end

    case result do
      {:ok, _} ->
        {:noreply, push_event(socket, "close-dialog", %{id: "folder-dialog"})}

      {:error, reason} ->
        form =
          to_form(%{"name" => name},
            as: :folder,
            errors: [name: {BastionWeb.Errors.message(reason), []}]
          )

        {:noreply, assign(socket, folder_form: form)}
    end
  end

  def handle_event("pick-move", %{"id" => id}, socket) do
    folder = socket.assigns.folders_by_id[id]

    {:noreply,
     assign(socket,
       moving_folder: folder,
       move_form: to_form(%{"parent_id" => folder.parent_id || ""}, as: :move)
     )}
  end

  def handle_event("move-folder", %{"move" => %{"parent_id" => parent_id}}, socket) do
    folder = socket.assigns.moving_folder

    parent_id = if(parent_id == "", do: nil, else: parent_id)

    case Fleet.move_folder(socket.assigns.current_actor, folder.id, parent_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(moving_folder: nil)
         |> push_event("close-dialog", %{id: "move-dialog"})}

      {:error, reason} ->
        form =
          to_form(%{"parent_id" => parent_id},
            as: :move,
            errors: [parent_id: {BastionWeb.Errors.message(reason), []}]
          )

        {:noreply, assign(socket, move_form: form)}
    end
  end

  def handle_event("delete-folder", %{"id" => id}, socket) do
    case Fleet.delete_folder(socket.assigns.current_actor, id) do
      :ok -> {:noreply, put_flash(socket, :info, gettext("Folder deleted"))}
      {:error, reason} -> {:noreply, put_flash(socket, :error, BastionWeb.Errors.message(reason))}
    end
  end

  @impl true
  def render(assigns) do
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
          <h1 class="text-2xl font-semibold">{gettext("Devices")}</h1>
          <p class="text-sm text-base-content/60">
            {ngettext("%{count} device", "%{count} devices", @total)}
          </p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <form phx-change="search" phx-submit="search" id="search-form" class="contents">
            <label class="input input-sm w-56">
              <.icon name="hero-magnifying-glass" class="size-4 opacity-60" />
              <input
                type="search"
                name="q"
                value={@query}
                placeholder={gettext("Name, MAC or IP")}
                phx-debounce="150"
              />
            </label>
          </form>
          <button
            :if={@can_root}
            type="button"
            class="btn btn-sm"
            phx-click={JS.push("new-folder") |> open_dialog("folder-dialog")}
            id="new-folder"
          >
            <.icon name="hero-folder-plus" class="size-4" /> {gettext("New folder")}
          </button>
          <.link
            :if={@can_approve}
            navigate={~p"/connect"}
            class="btn btn-sm btn-primary"
            id="how-to-connect"
          >
            <.icon name="hero-plus" class="size-4" /> {gettext("Connect a device")}
          </.link>
        </div>
      </div>

      <div class="flex flex-wrap items-center gap-3 rounded-box border border-base-300 bg-base-100 px-4 py-3 text-sm">
        <.icon name="hero-shield-check" class="size-5 text-success" />
        <span class="text-base-content/70">{gettext("Bastion code")}</span>
        <.code code={@bastion_code} id="bastion-code" />
        <span class="text-base-content/50">
          {gettext("compare it with the code shown in the device setup wizard")}
        </span>
      </div>

      <section :if={@overview.requests != []} id="requests" class="space-y-3">
        <h2 class="flex items-center gap-2 text-lg font-semibold">
          <.icon name="hero-bell-alert" class="size-5 text-warning" />
          {gettext("Requests")}
          <span class="badge badge-warning badge-sm">{length(@overview.requests)}</span>
        </h2>
        <div class="grid gap-3 md:grid-cols-2">
          <div
            :for={device <- @overview.requests}
            id={"request-#{device.id}"}
            class="card border border-warning/40 bg-base-100 shadow-sm"
          >
            <div class="card-body gap-3 p-4">
              <div class="flex items-start justify-between gap-3">
                <div>
                  <.link navigate={~p"/devices/#{device.id}"} class="font-semibold hover:underline">{device.name}</.link>
                  <p class="font-mono text-xs text-base-content/60">
                    {Fleet.format_mac(device.device_id)}
                  </p>
                </div>
                <.time at={device.requested_at} format="relative" id={"requested-#{device.id}"} />
              </div>
              <div class="flex flex-wrap items-center gap-2 text-sm">
                <span class="text-base-content/60">{gettext("Device code")}</span>
                <.code code={device.device_code} />
                <span :if={device.last_ip} class="text-base-content/50">· {device.last_ip}</span>
              </div>
              <div class="card-actions justify-end">
                <button
                  type="button"
                  class="btn btn-ghost btn-sm"
                  phx-click="reject"
                  phx-value-id={device.id}
                  data-confirm={gettext("Reject the request from %{name}?", name: device.name)}
                >
                  {gettext("Reject")}
                </button>
                <button
                  type="button"
                  class="btn btn-success btn-sm"
                  id={"approve-#{device.id}"}
                  phx-click={
                    JS.push("confirm-approve", value: %{id: device.id})
                    |> open_dialog("approve-dialog")
                  }
                >
                  <.icon name="hero-check" class="size-4" /> {gettext("Approve")}
                </button>
              </div>
            </div>
          </div>
        </div>
      </section>

      <div
        :if={@total == 0}
        class="rounded-box border border-dashed border-base-300 px-6 py-16 text-center"
        id="empty"
      >
        <.icon name="hero-cpu-chip" class="mx-auto size-12 text-base-content/30" />
        <h2 class="mt-3 text-lg font-semibold">{gettext("No devices yet")}</h2>
        <p class="mx-auto mt-1 max-w-md text-sm text-base-content/60">
          {gettext(
            "Set up an ESP WCS device in Bastion mode with this bastion's address — its request will appear here."
          )}
        </p>
        <.link navigate={~p"/connect"} class="btn btn-primary btn-sm mt-4">{gettext("How to connect")}</.link>
      </div>

      <section :if={@total > 0 or @tree != []} id="devices" class="space-y-3">
        <.folder_node
          :for={node <- @tree}
          node={node}
          devices={@overview.devices}
          query={@query}
          collapsed={@collapsed}
          online={@online}
          dim={@overview.dim}
          actor={@current_actor}
        />
        <.device_group
          :if={@overview.unfiled != []}
          id="folder-none"
          devices={filter(@overview.unfiled, @query)}
          all_count={length(@overview.unfiled)}
          collapsed={MapSet.member?(@collapsed, "none")}
          online={@online}
        />
      </section>

      <.dialog id="approve-dialog" title={gettext("Approve the device?")}>
        <div :if={@approving} class="space-y-3 text-sm">
          <p>
            {gettext(
              "Make sure the code below matches the device code on the last step of the setup wizard of %{name}.",
              name: @approving.name
            )}
          </p>
          <div class="flex justify-center py-2">
            <.code code={@approving.device_code} size="lg" />
          </div>
          <p class="text-base-content/60">
            {gettext(
              "If the codes differ, someone else may be posing as your device — reject the request."
            )}
          </p>
        </div>
        <:actions>
          <button type="button" class="btn btn-ghost" phx-click={close_dialog("approve-dialog")}>{gettext(
            "Cancel"
          )}</button>
          <button
            :if={@approving}
            type="button"
            class="btn btn-success"
            phx-click="approve"
            phx-value-id={@approving.id}
            phx-value-code={@approving.device_code}
            id="approve-confirm"
          >
            {gettext("Codes match, approve")}
          </button>
        </:actions>
      </.dialog>

      <.dialog
        id="folder-dialog"
        title={folder_dialog_title(@folder_mode)}
      >
        <p :if={match?({:new, %Folder{}}, @folder_mode)} class="text-sm text-base-content/60">
          {gettext("Inside “%{folder}”",
            folder: Folder.full_name(elem(@folder_mode, 1), @folders_by_id)
          )}
        </p>
        <.form for={@folder_form} id="folder-form" phx-submit="save-folder">
          <.input
            field={@folder_form[:name]}
            label={gettext("Name")}
            maxlength={Fleet.name_max_length()}
            required
            autocomplete="off"
          />
          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click={close_dialog("folder-dialog")}>{gettext(
              "Cancel"
            )}</button>
            <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
          </div>
        </.form>
      </.dialog>

      <.dialog id="move-dialog" title={gettext("Move folder")}>
        <.form :if={@moving_folder} for={@move_form} id="move-form" phx-submit="move-folder">
          <p class="text-sm">
            {gettext("Move “%{folder}” with everything inside into:",
              folder: Folder.full_name(@moving_folder, @folders_by_id)
            )}
          </p>
          <.input
            field={@move_form[:parent_id]}
            type="select"
            options={move_targets(@overview.folders, @moving_folder, @folders_by_id)}
          />
          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click={close_dialog("move-dialog")}>{gettext(
              "Cancel"
            )}</button>
            <button type="submit" class="btn btn-primary">{gettext("Move")}</button>
          </div>
        </.form>
      </.dialog>
    </Layouts.app>
    """
  end

  defp folder_dialog_title({:rename, _}), do: gettext("Rename folder")
  defp folder_dialog_title({:new, nil}), do: gettext("New folder")
  defp folder_dialog_title({:new, _}), do: gettext("New subfolder")

  defp move_targets(folders, moving, by_id) do
    targets =
      folders
      |> Enum.reject(&(&1.id == moving.id or Folder.inside?(&1, moving)))
      |> Enum.map(&{Folder.full_name(&1, by_id), &1.id})

    [{gettext("Top level"), ""} | targets]
  end

  attr :node, :any, required: true
  attr :devices, :map, required: true
  attr :query, :string, required: true
  attr :collapsed, :any, required: true
  attr :online, :map, default: %{}
  attr :dim, :any, required: true
  attr :actor, :any, required: true

  defp folder_node(assigns) do
    {folder, children} = assigns.node
    own = Map.get(assigns.devices, folder.id, [])
    subtree = subtree_devices(assigns.node, assigns.devices)

    assigns =
      assign(assigns,
        folder: folder,
        children: children,
        own: filter(own, assigns.query),
        own_count: length(own),
        subtree_count: length(subtree),
        visible: assigns.query == "" or filter(subtree, assigns.query) != [],
        collapsed?: assigns.query == "" and MapSet.member?(assigns.collapsed, folder.id),
        deletable: own == [] and children == [],
        dim?: MapSet.member?(assigns.dim, folder.id),
        manage?: Fleet.can_folder?(assigns.actor, "folder.manage", folder)
      )

    ~H"""
    <div
      :if={@visible}
      id={"folder-#{@folder.id}"}
      class="rounded-box border border-base-300 bg-base-100"
    >
      <div class="flex items-center gap-2 px-4 py-3">
        <button
          type="button"
          class="flex flex-1 items-center gap-2 text-left"
          phx-click="toggle-folder"
          phx-value-id={@folder.id}
          aria-expanded={to_string(!@collapsed?)}
        >
          <.icon
            name="hero-chevron-right"
            class={["size-4 transition-transform", !@collapsed? && "rotate-90"]}
          />
          <.icon name="hero-folder" class="size-5 text-base-content/60" />
          <span class={["font-medium", @dim? && "text-base-content/50"]}>{@folder.name}</span>
          <span class="badge badge-ghost badge-sm" title={gettext("Devices inside, with subfolders")}>
            {@subtree_count}
          </span>
        </button>
        <div :if={@manage?} class="dropdown dropdown-end">
          <div
            tabindex="0"
            role="button"
            class="btn btn-ghost btn-xs"
            aria-label={gettext("Folder actions")}
            id={"folder-menu-#{@folder.id}"}
          >
            <.icon name="hero-ellipsis-horizontal" class="size-4" />
          </div>
          <ul tabindex="0" class="menu dropdown-content z-10 w-52 rounded-box bg-base-100 p-1 shadow">
            <li :if={Folder.depth(@folder) < Folder.max_depth()}>
              <button
                type="button"
                id={"new-subfolder-#{@folder.id}"}
                phx-click={
                  JS.push("new-folder", value: %{parent: @folder.id}) |> open_dialog("folder-dialog")
                }
              >
                <.icon name="hero-folder-plus" class="size-4" /> {gettext("New subfolder")}
              </button>
            </li>
            <li>
              <button
                type="button"
                id={"rename-folder-#{@folder.id}"}
                phx-click={
                  JS.push("edit-folder", value: %{id: @folder.id}) |> open_dialog("folder-dialog")
                }
              >
                <.icon name="hero-pencil" class="size-4" /> {gettext("Rename")}
              </button>
            </li>
            <li>
              <button
                type="button"
                id={"move-folder-#{@folder.id}"}
                phx-click={
                  JS.push("pick-move", value: %{id: @folder.id}) |> open_dialog("move-dialog")
                }
              >
                <.icon name="hero-arrows-right-left" class="size-4" /> {gettext("Move")}
              </button>
            </li>
            <li :if={@deletable}>
              <button
                type="button"
                class="text-error"
                id={"delete-folder-#{@folder.id}"}
                phx-click="delete-folder"
                phx-value-id={@folder.id}
                data-confirm={gettext("Delete folder “%{name}”?", name: @folder.name)}
              >
                <.icon name="hero-trash" class="size-4" /> {gettext("Delete")}
              </button>
            </li>
            <li :if={!@deletable} class="menu-disabled">
              <span class="text-xs">{gettext("Only an empty folder can be deleted")}</span>
            </li>
          </ul>
        </div>
      </div>

      <div :if={!@collapsed?} class="border-t border-base-300">
        <div :if={@children != []} class="space-y-2 p-2 pl-6">
          <.folder_node
            :for={child <- @children}
            node={child}
            devices={@devices}
            query={@query}
            collapsed={@collapsed}
            online={@online}
            dim={@dim}
            actor={@actor}
          />
        </div>
        <p
          :if={@own == [] and @children == []}
          class="px-4 py-4 text-sm text-base-content/50"
        >
          {if(@own_count == 0,
            do: gettext("The folder is empty — add devices here from their settings"),
            else: gettext("Nothing found")
          )}
        </p>
        <.device_list :if={@own != []} devices={@own} online={@online} scope={@folder.id} />
      </div>
    </div>
    """
  end

  defp subtree_devices({folder, children}, devices) do
    (Map.get(devices, folder.id, []) ++ Enum.flat_map(children, &subtree_devices(&1, devices)))
    |> Enum.uniq_by(& &1.id)
  end

  attr :id, :string, required: true
  attr :devices, :list, required: true
  attr :all_count, :integer, required: true
  attr :collapsed, :boolean, default: false
  attr :online, :map, default: %{}

  defp device_group(assigns) do
    ~H"""
    <div id={@id} class="rounded-box border border-base-300 bg-base-100">
      <div class="flex items-center gap-2 px-4 py-3">
        <button
          type="button"
          class="flex flex-1 items-center gap-2 text-left"
          phx-click="toggle-folder"
          phx-value-id="none"
          aria-expanded={to_string(!@collapsed)}
        >
          <.icon
            name="hero-chevron-right"
            class={["size-4 transition-transform", !@collapsed && "rotate-90"]}
          />
          <.icon name="hero-inbox" class="size-5 text-base-content/60" />
          <span class="font-medium">{gettext("No folder")}</span>
          <span class="badge badge-ghost badge-sm">{@all_count}</span>
        </button>
      </div>
      <div :if={!@collapsed} class="border-t border-base-300">
        <p :if={@devices == []} class="px-4 py-4 text-sm text-base-content/50">
          {gettext("Nothing found")}
        </p>
        <.device_list :if={@devices != []} devices={@devices} online={@online} scope="none" />
      </div>
    </div>
    """
  end

  attr :devices, :list, required: true
  attr :online, :map, default: %{}
  attr :scope, :string, required: true

  defp device_list(assigns) do
    ~H"""
    <ul class="divide-y divide-base-300">
      <li :for={device <- @devices} id={"device-#{@scope}-#{device.id}"}>
        <.link
          navigate={~p"/devices/#{device.id}"}
          class="flex flex-wrap items-center gap-x-4 gap-y-1 px-4 py-3 transition-colors hover:bg-base-200/60"
        >
          <span class="min-w-40 font-medium">{device.name}</span>
          <span class="font-mono text-xs text-base-content/50">{Fleet.format_mac(device.device_id)}</span>
          <span class="flex-1"></span>
          <.presence
            :if={device.status == :approved}
            device={device}
            online={@online[device.id]}
            scope={@scope}
          />
          <.status_badge :if={device.status != :approved} status={device.status} />
          <.icon name="hero-chevron-right" class="size-4 text-base-content/30" />
        </.link>
      </li>
    </ul>
    """
  end

  defp filter(devices, ""), do: devices

  defp filter(devices, query) do
    query = String.downcase(query)
    compact = String.replace(query, ":", "")

    Enum.filter(devices, fn d ->
      String.contains?(String.downcase(d.name), query) or String.contains?(d.device_id, compact) or
        (d.last_ip && String.contains?(d.last_ip, query))
    end)
  end
end
