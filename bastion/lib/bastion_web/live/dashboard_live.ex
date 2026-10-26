defmodule BastionWeb.DashboardLive do
  @moduledoc """
  Главная: код бастиона, заявки на одобрение, устройства по папкам, поиск.
  Обновляется сама по событиям контекста Fleet.
  """
  use BastionWeb, :live_view

  alias Bastion.Fleet

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Fleet.subscribe()

    socket =
      socket
      |> assign(
        page_title: gettext("Devices"),
        bastion_code: Bastion.PKI.bastion_code(),
        query: "",
        approving: nil,
        folder_form: to_form(%{"name" => ""}, as: :folder),
        editing_folder: nil,
        collapsed: MapSet.new()
      )
      |> load()

    {:ok, socket}
  end

  defp load(socket) do
    overview = Fleet.overview()
    assign(socket, overview: overview, total: count(overview))
  end

  defp count(%{folders: folders, unfiled: unfiled}),
    do: Enum.reduce(folders, length(unfiled), fn {_, devices}, acc -> acc + length(devices) end)

  # ---- события Fleet ----

  @impl true
  def handle_info({:event, _event}, socket), do: {:noreply, load(socket)}

  # ---- поиск ----

  @impl true
  def handle_event("search", %{"q" => query}, socket),
    do: {:noreply, assign(socket, query: String.trim(query))}

  # ---- заявки ----

  def handle_event("confirm-approve", %{"id" => id}, socket) do
    device = Enum.find(socket.assigns.overview.requests, &(&1.id == id))
    {:noreply, assign(socket, approving: device)}
  end

  def handle_event("approve", %{"id" => id}, socket) do
    socket = push_event(socket, "close-dialog", %{id: "approve-dialog"})

    case Fleet.approve(id) do
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
    case Fleet.reject(id) do
      {:ok, _} -> {:noreply, put_flash(socket, :info, gettext("Request rejected"))}
      {:error, reason} -> {:noreply, put_flash(socket, :error, BastionWeb.Errors.message(reason))}
    end
  end

  # ---- папки ----

  def handle_event("toggle-folder", %{"id" => id}, socket) do
    collapsed = socket.assigns.collapsed

    collapsed =
      if MapSet.member?(collapsed, id),
        do: MapSet.delete(collapsed, id),
        else: MapSet.put(collapsed, id)

    {:noreply, assign(socket, collapsed: collapsed)}
  end

  def handle_event("new-folder", _params, socket) do
    {:noreply,
     assign(socket, editing_folder: nil, folder_form: to_form(%{"name" => ""}, as: :folder))}
  end

  def handle_event("edit-folder", %{"id" => id}, socket) do
    folder = Enum.find_value(socket.assigns.overview.folders, fn {f, _} -> f.id == id && f end)

    {:noreply,
     assign(socket,
       editing_folder: folder,
       folder_form: to_form(%{"name" => folder.name}, as: :folder)
     )}
  end

  def handle_event("save-folder", %{"folder" => %{"name" => name}}, socket) do
    result =
      case socket.assigns.editing_folder do
        nil -> Fleet.create_folder(name)
        folder -> Fleet.rename_folder(folder.id, name)
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

  def handle_event("delete-folder", %{"id" => id}, socket) do
    :ok = Fleet.delete_folder(id)

    {:noreply,
     put_flash(socket, :info, gettext("Folder deleted, its devices moved to “No folder”"))}
  end

  # ---- отображение ----

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_admin={@current_admin}
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
            type="button"
            class="btn btn-sm"
            phx-click={JS.push("new-folder") |> open_dialog("folder-dialog")}
            id="new-folder"
          >
            <.icon name="hero-folder-plus" class="size-4" /> {gettext("New folder")}
          </button>
          <.link navigate={~p"/connect"} class="btn btn-sm btn-primary" id="how-to-connect">
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

      <section :if={@total > 0} id="devices" class="space-y-3">
        <.folder
          :for={{folder, devices} <- @overview.folders}
          id={"folder-#{folder.id}"}
          folder={folder}
          devices={filter(devices, @query)}
          all_count={length(devices)}
          collapsed={MapSet.member?(@collapsed, folder.id)}
        />
        <.folder
          :if={@overview.unfiled != []}
          id="folder-none"
          folder={nil}
          devices={filter(@overview.unfiled, @query)}
          all_count={length(@overview.unfiled)}
          collapsed={MapSet.member?(@collapsed, "none")}
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
            id="approve-confirm"
          >
            {gettext("Codes match, approve")}
          </button>
        </:actions>
      </.dialog>

      <.dialog
        id="folder-dialog"
        title={if(@editing_folder, do: gettext("Rename folder"), else: gettext("New folder"))}
      >
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
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :folder, :any, required: true, doc: "папка или nil — «Без папки»"
  attr :devices, :list, required: true
  attr :all_count, :integer, required: true
  attr :collapsed, :boolean, default: false

  defp folder(assigns) do
    assigns = assign(assigns, :key, if(assigns.folder, do: assigns.folder.id, else: "none"))

    ~H"""
    <div id={@id} class="rounded-box border border-base-300 bg-base-100">
      <div class="flex items-center gap-2 px-4 py-3">
        <button
          type="button"
          class="flex flex-1 items-center gap-2 text-left"
          phx-click="toggle-folder"
          phx-value-id={@key}
          aria-expanded={to_string(!@collapsed)}
        >
          <.icon
            name="hero-chevron-right"
            class={["size-4 transition-transform", !@collapsed && "rotate-90"]}
          />
          <.icon
            name={if(@folder, do: "hero-folder", else: "hero-inbox")}
            class="size-5 text-base-content/60"
          />
          <span class="font-medium">{if(@folder, do: @folder.name, else: gettext("No folder"))}</span>
          <span class="badge badge-ghost badge-sm">{@all_count}</span>
        </button>
        <div :if={@folder} class="dropdown dropdown-end">
          <div
            tabindex="0"
            role="button"
            class="btn btn-ghost btn-xs"
            aria-label={gettext("Folder actions")}
          >
            <.icon name="hero-ellipsis-horizontal" class="size-4" />
          </div>
          <ul tabindex="0" class="menu dropdown-content z-10 w-44 rounded-box bg-base-100 p-1 shadow">
            <li>
              <button
                type="button"
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
                class="text-error"
                phx-click="delete-folder"
                phx-value-id={@folder.id}
                data-confirm={
                  gettext("Delete folder “%{name}”? Devices will move to “No folder”.",
                    name: @folder.name
                  )
                }
              >
                <.icon name="hero-trash" class="size-4" /> {gettext("Delete")}
              </button>
            </li>
          </ul>
        </div>
      </div>

      <div :if={!@collapsed}>
        <p
          :if={@devices == []}
          class="border-t border-base-300 px-4 py-4 text-sm text-base-content/50"
        >
          {if(@all_count == 0,
            do: gettext("The folder is empty — move devices here from their settings"),
            else: gettext("Nothing found")
          )}
        </p>

        <ul :if={@devices != []} class="divide-y divide-base-300 border-t border-base-300">
          <li :for={device <- @devices} id={"device-#{device.id}"}>
            <.link
              navigate={~p"/devices/#{device.id}"}
              class="flex flex-wrap items-center gap-x-4 gap-y-1 px-4 py-3 transition-colors hover:bg-base-200/60"
            >
              <span class="min-w-40 font-medium">{device.name}</span>
              <span class="font-mono text-xs text-base-content/50">{Fleet.format_mac(device.device_id)}</span>
              <span class="flex-1"></span>
              <.presence :if={device.status == :approved} device={device} />
              <.status_badge :if={device.status != :approved} status={device.status} />
              <.icon name="hero-chevron-right" class="size-4 text-base-content/30" />
            </.link>
          </li>
        </ul>
      </div>
    </div>
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
