defmodule BastionWeb.DeviceLive do
  use BastionWeb, :live_view

  alias Bastion.Console
  alias Bastion.Console.Events.{ConsoleTaken, LockChanged}
  alias Bastion.Fleet
  alias Bastion.Link.Events.{ConsoleOutput, PresenceChanged}

  @tabs [:console, :settings, :info, :journal]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Fleet.get_device(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, BastionWeb.Errors.message(:not_found))
         |> push_navigate(to: ~p"/")}

      device ->
        if connected?(socket) do
          Fleet.subscribe(device.id)
          Fleet.subscribe()
          Console.subscribe(device.id)
        end

        {:ok,
         socket
         |> assign(
           device: device,
           folders: Fleet.list_folders(),
           online: Bastion.Link.presence(device.id),
           console: :idle,
           console_since: nil
         )
         |> assign_forms()}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    tab = socket.assigns.live_action

    socket =
      socket
      |> assign(tab: tab, page_title: "#{socket.assigns.device.name} · #{tab_title(tab)}")
      |> then(fn s ->
        if tab == :journal, do: assign(s, events: Fleet.list_events(s.assigns.device.id)), else: s
      end)
      |> sync_console()

    {:noreply, socket}
  end

  defp sync_console(socket) do
    %{device: device, tab: tab, console: console} = socket.assigns
    wanted? = connected?(socket) and tab == :console and device.status == :approved

    cond do
      wanted? and console != :owner -> attach_console(socket)
      not wanted? and console == :owner -> release_console(socket)
      not wanted? -> assign(socket, console: :idle)
      true -> socket
    end
  end

  defp attach_console(socket) do
    case Console.attach(socket.assigns.device.id) do
      {:ok, history} -> owner(socket, history)
      {:busy, since} -> busy(socket, since)
    end
  end

  defp release_console(socket) do
    Console.release(socket.assigns.device.id)
    socket |> assign(console: :idle) |> push_event("console-state", %{owner: false})
  end

  defp owner(socket, history) do
    socket
    |> assign(console: :owner, console_since: nil)
    |> push_event("console-reset", %{data: Base.encode64(history)})
    |> push_event("console-state", %{owner: true})
  end

  defp busy(socket, since) do
    socket
    |> assign(console: :busy, console_since: since)
    |> push_event("console-state", %{owner: false})
  end

  defp assign_forms(socket) do
    device = socket.assigns.device

    assign(socket,
      name_form: to_form(%{"name" => device.name}, as: :device),
      folder_form: to_form(%{"folder_id" => device.folder_id || ""}, as: :device)
    )
  end

  defp reload(socket) do
    case Fleet.get_device(socket.assigns.device.id) do
      nil ->
        socket |> put_flash(:info, gettext("The device was deleted")) |> push_navigate(to: ~p"/")

      device ->
        socket = socket |> assign(device: device, folders: Fleet.list_folders()) |> assign_forms()

        if socket.assigns.tab == :journal,
          do: assign(socket, events: Fleet.list_events(device.id)),
          else: socket
    end
  end

  @impl true
  def handle_info(
        {:event, %PresenceChanged{id: id}},
        %{assigns: %{device: %{id: id}}} = socket
      ),
      do: {:noreply, assign(socket, online: Bastion.Link.presence(id))}

  def handle_info({:event, %PresenceChanged{}}, socket), do: {:noreply, socket}

  def handle_info({:event, %ConsoleOutput{data: data}}, %{assigns: %{console: :owner}} = socket),
    do: {:noreply, push_event(socket, "console-output", %{data: Base.encode64(data)})}

  def handle_info({:event, %ConsoleOutput{}}, socket), do: {:noreply, socket}

  def handle_info({:event, %ConsoleTaken{id: id}}, socket) do
    Console.lost(id)

    since =
      case Console.lock(id) do
        {:owned, _pid, since} -> since
        :free -> DateTime.utc_now(:second)
      end

    {:noreply, busy(socket, since)}
  end

  def handle_info({:event, %LockChanged{owned: false}}, %{assigns: %{console: :busy}} = socket),
    do: {:noreply, sync_console(socket)}

  def handle_info({:event, %LockChanged{owned: true}}, %{assigns: %{console: :busy}} = socket) do
    case Console.lock(socket.assigns.device.id) do
      {:owned, pid, since} when pid != self() -> {:noreply, assign(socket, console_since: since)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:event, %LockChanged{}}, socket), do: {:noreply, socket}

  def handle_info({:event, _event}, socket), do: {:noreply, socket |> reload() |> sync_console()}

  @impl true
  def handle_event("console-input", %{"data" => data}, %{assigns: %{console: :owner}} = socket)
      when is_binary(data) do
    Console.input(socket.assigns.device.id, data)
    {:noreply, socket}
  end

  def handle_event("console-input", _params, socket), do: {:noreply, socket}

  def handle_event("console-ping", _params, socket), do: {:noreply, socket}

  def handle_event("console-take", _params, socket) do
    {:ok, history} = Console.take(socket.assigns.device.id)
    {:noreply, owner(socket, history)}
  end

  def handle_event("console-break", _params, %{assigns: %{console: :owner}} = socket) do
    id = socket.assigns.device.id
    lv = self()
    {:noreply, start_async(socket, :console_break, fn -> Console.send_break(id, lv) end)}
  end

  def handle_event("console-break", _params, socket), do: {:noreply, socket}

  def handle_event("console-line", %{"line" => params}, socket) do
    id = socket.assigns.device.id
    {:noreply, start_async(socket, :console_line, fn -> Console.configure(id, params) end)}
  end

  def handle_event("rename", %{"device" => %{"name" => name}}, socket) do
    case Fleet.rename(socket.assigns.device.id, name) do
      {:ok, _} ->
        {:noreply, socket |> reload() |> put_flash(:info, gettext("Name saved"))}

      {:error, reason} ->
        form =
          to_form(%{"name" => name},
            as: :device,
            errors: [name: {BastionWeb.Errors.message(reason), []}]
          )

        {:noreply, assign(socket, name_form: form)}
    end
  end

  def handle_event("move", %{"device" => %{"folder_id" => folder_id}}, socket) do
    case Fleet.move(socket.assigns.device.id, if(folder_id == "", do: nil, else: folder_id)) do
      {:ok, _} -> {:noreply, socket |> reload() |> put_flash(:info, gettext("Folder changed"))}
      {:error, reason} -> {:noreply, put_flash(socket, :error, BastionWeb.Errors.message(reason))}
    end
  end

  def handle_event("approve", %{"code" => code}, socket),
    do: lifecycle(socket, &Fleet.approve(&1, code), gettext("Device approved"))

  def handle_event("reject", _params, socket),
    do: lifecycle(socket, &Fleet.reject/1, gettext("Request rejected"))

  def handle_event("revoke", _params, socket),
    do: lifecycle(socket, &Fleet.revoke/1, gettext("Device revoked"))

  def handle_event("delete", _params, socket) do
    case Fleet.delete(socket.assigns.device.id) do
      {:ok, :deleted} ->
        {:noreply,
         socket |> put_flash(:info, gettext("Device deleted")) |> push_navigate(to: ~p"/")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, BastionWeb.Errors.message(reason))}
    end
  end

  @impl true
  def handle_async(op, {:ok, :ok}, socket) when op in [:console_break, :console_line] do
    message =
      if op == :console_break, do: gettext("BREAK sent"), else: gettext("Port settings applied")

    {:noreply, put_flash(socket, :info, message)}
  end

  def handle_async(_op, {:ok, {:error, reason}}, socket),
    do: {:noreply, put_flash(socket, :error, BastionWeb.Errors.message(reason))}

  def handle_async(_op, {:exit, _reason}, socket),
    do: {:noreply, put_flash(socket, :error, BastionWeb.Errors.message(:failed))}

  defp lifecycle(socket, fun, success) do
    socket = push_event(socket, "close-dialog", %{id: "approve-dialog"})

    case fun.(socket.assigns.device.id) do
      {:ok, :deleted} ->
        {:noreply, socket |> put_flash(:info, success) |> push_navigate(to: ~p"/")}

      {:ok, _} ->
        {:noreply, socket |> reload() |> put_flash(:info, success)}

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
      current_admin={@current_admin}
      locale={@locale}
      current_path={@current_path}
    >
      <.link
        navigate={~p"/"}
        class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content"
      >
        <.icon name="hero-arrow-left" class="size-4" /> {gettext("All devices")}
      </.link>

      <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
        <h1 class="text-2xl font-semibold" id="device-name">{@device.name}</h1>
        <.status_badge status={@device.status} />
        <.presence :if={@device.status == :approved} device={@device} online={@online} />
      </div>

      <div
        :if={@device.status == :pending}
        id="request-banner"
        class="alert alert-warning alert-soft items-start"
      >
        <.icon name="hero-bell-alert" class="size-6" />
        <div class="flex-1 space-y-1">
          <p class="font-medium">{gettext("The device is waiting for approval")}</p>
          <p class="text-sm">
            {gettext("Compare the device code with the last step of the setup wizard:")}
            <.code code={@device.device_code} />
          </p>
        </div>
        <div class="flex gap-2">
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="reject"
            data-confirm={gettext("Reject the request from %{name}?", name: @device.name)}
          >
            {gettext("Reject")}
          </button>
          <button
            type="button"
            class="btn btn-success btn-sm"
            phx-click={open_dialog("approve-dialog")}
            id="approve"
          >
            <.icon name="hero-check" class="size-4" /> {gettext("Approve")}
          </button>
        </div>
      </div>

      <div role="tablist" class="tabs tabs-border" id="device-tabs">
        <.link
          :for={tab <- @tabs}
          patch={tab_path(@device, tab)}
          role="tab"
          id={"tab-#{tab}"}
          class={["tab gap-2", @tab == tab && "tab-active"]}
          aria-selected={to_string(@tab == tab)}
        >
          <.icon name={tab_icon(tab)} class="size-4" /> {tab_title(tab)}
        </.link>
      </div>

      <.console_tab
        :if={@tab == :console}
        device={@device}
        online={@online}
        console={@console}
        since={@console_since}
      />
      <.settings_tab
        :if={@tab == :settings}
        device={@device}
        name_form={@name_form}
        folder_form={@folder_form}
        folders={@folders}
      />
      <.info_tab :if={@tab == :info} device={@device} online={@online} />
      <.journal_tab :if={@tab == :journal} events={@events} />

      <.dialog id="approve-dialog" title={gettext("Approve the device?")}>
        <p class="text-sm">
          {gettext(
            "Make sure the code below matches the device code on the last step of the setup wizard of %{name}.",
            name: @device.name
          )}
        </p>
        <div class="flex justify-center py-2"><.code code={@device.device_code} size="lg" /></div>
        <:actions>
          <button type="button" class="btn btn-ghost" phx-click={close_dialog("approve-dialog")}>{gettext(
            "Cancel"
          )}</button>
          <button
            type="button"
            class="btn btn-success"
            phx-click="approve"
            phx-value-code={@device.device_code}
            id="approve-confirm"
          >{gettext("Codes match, approve")}</button>
        </:actions>
      </.dialog>
    </Layouts.app>
    """
  end

  attr :device, :map, required: true
  attr :online, :map, default: nil
  attr :console, :atom, required: true
  attr :since, :any, default: nil

  defp console_tab(assigns) do
    banner = ["\e[1;36mESP WCS\e[0m · #{assigns.device.name}", ""]
    line = assigns.online && assigns.online[:console]

    assigns =
      assign(assigns,
        banner: JSON.encode!(banner),
        line: line,
        line_form: to_form(line_params(line), as: :line)
      )

    ~H"""
    <section class="space-y-3" id="console">
      <.form
        for={@line_form}
        id="console-line"
        phx-change="console-line"
        class="flex flex-wrap items-center gap-2"
      >
        <select
          name="line[baud]"
          class="select select-sm w-32"
          disabled={!@online}
          aria-label={gettext("Baud rate")}
        >
          <option
            :for={baud <- Console.bauds()}
            value={baud}
            selected={@line_form[:baud].value == baud}
          >
            {baud}
          </option>
        </select>
        <select
          name="line[data_bits]"
          class="select select-sm w-20"
          disabled={!@online}
          aria-label={gettext("Data bits")}
        >
          <option :for={bits <- 8..5//-1} value={bits} selected={@line_form[:data_bits].value == bits}>
            {bits}
          </option>
        </select>
        <select
          name="line[parity]"
          class="select select-sm w-28"
          disabled={!@online}
          aria-label={gettext("Parity")}
        >
          <option
            :for={{label, value} <- parity_options()}
            value={value}
            selected={@line_form[:parity].value == value}
          >
            {label}
          </option>
        </select>
        <select
          name="line[stop_bits]"
          class="select select-sm w-20"
          disabled={!@online}
          aria-label={gettext("Stop bits")}
        >
          <option :for={stop <- [1, 2]} value={stop} selected={@line_form[:stop_bits].value == stop}>
            {stop}
          </option>
        </select>
        <span :if={@line} class="text-sm text-base-content/50" id="console-line-current">
          {Console.format_line(@line)}
        </span>
        <span class="flex-1"></span>
        <button
          type="button"
          class="btn btn-sm"
          id="console-break"
          phx-click="console-break"
          disabled={@console != :owner}
          title={gettext("Send BREAK")}
        >
          <.icon name="hero-bolt" class="size-4" /> BREAK
        </button>
      </.form>

      <div
        :if={@console == :busy}
        id="console-busy"
        class="alert alert-warning alert-soft items-start"
      >
        <.icon name="hero-lock-closed" class="size-6" />
        <div class="flex-1 space-y-1">
          <p class="font-medium">{gettext("Device busy")}</p>
          <p class="text-sm">
            {gettext("The console is open in another tab or browser.")}
            <span :if={@since}>
              {gettext("Since")} <.time at={@since} format="relative" id="console-busy-since" />
            </span>
          </p>
        </div>
        <button
          type="button"
          class="btn btn-sm btn-primary"
          id="console-take"
          phx-click="console-take"
          data-confirm={gettext("Take the console? The other tab will lose control.")}
        >
          <.icon name="hero-hand-raised" class="size-4" /> {gettext("Take the console")}
        </button>
      </div>

      <div
        :if={@device.status == :approved and !@online}
        id="console-offline"
        class="alert alert-soft"
      >
        <.icon name="hero-signal-slash" class="size-6" />
        <span>{gettext("The device is offline. The console will open when it connects.")}</span>
      </div>

      <div
        :if={@device.status != :approved}
        id="console-unavailable"
        class="alert alert-soft"
      >
        <.icon name="hero-information-circle" class="size-6" />
        <span>{gettext("The console is available for approved devices only.")}</span>
      </div>

      <div
        id={"terminal-#{@device.id}"}
        phx-hook="Terminal"
        phx-update="ignore"
        data-readonly="true"
        data-banner={@banner}
        class="h-[28rem] overflow-hidden rounded-box border border-base-300 bg-base-200 p-2"
      >
      </div>
    </section>
    """
  end

  defp line_params(nil),
    do: %{"baud" => 9600, "data_bits" => 8, "parity" => "none", "stop_bits" => 1}

  defp line_params(line),
    do: %{
      "baud" => line.baud,
      "data_bits" => line.data_bits,
      "parity" => to_string(line.parity),
      "stop_bits" => line.stop_bits
    }

  defp parity_options,
    do: [{gettext("No parity"), "none"}, {gettext("Even"), "even"}, {gettext("Odd"), "odd"}]

  attr :device, :map, required: true
  attr :name_form, :map, required: true
  attr :folder_form, :map, required: true
  attr :folders, :list, required: true

  defp settings_tab(assigns) do
    ~H"""
    <section class="grid gap-4 lg:grid-cols-2" id="settings">
      <.card title={gettext("Name")}>
        <.form for={@name_form} id="rename-form" phx-submit="rename" class="flex items-start gap-2">
          <div class="flex-1">
            <.input
              field={@name_form[:name]}
              maxlength={Fleet.name_max_length()}
              required
              autocomplete="off"
            />
          </div>
          <button type="submit" class="btn btn-primary mt-1">{gettext("Save")}</button>
        </.form>
      </.card>

      <.card title={gettext("Folder")}>
        <.form for={@folder_form} id="folder-form" phx-change="move">
          <.input
            field={@folder_form[:folder_id]}
            type="select"
            options={[{gettext("No folder"), ""} | Enum.map(@folders, &{&1.name, &1.id})]}
          />
        </.form>
      </.card>

      <.card title={gettext("Console port")} note={gettext("Available when the device is online")}>
        <div class="grid grid-cols-2 gap-3 opacity-60">
          <label class="text-sm">
            {gettext("Baud rate")}
            <select class="select select-sm mt-1 w-full" disabled><option>9600</option></select>
          </label>
          <label class="text-sm">
            {gettext("Format")}
            <select class="select select-sm mt-1 w-full" disabled><option>8N1</option></select>
          </label>
        </div>
      </.card>

      <.card title={gettext("Device Wi-Fi")} note={gettext("Available when the device is online")}>
        <p class="flex items-start gap-2 text-sm text-warning">
          <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
          {gettext(
            "With a wrong password the device loses its connection and can only be recovered with the button on site."
          )}
        </p>
      </.card>

      <div class="rounded-box border border-error/40 bg-base-100 p-4 lg:col-span-2" id="danger-zone">
        <h2 class="font-semibold text-error">{gettext("Danger zone")}</h2>
        <div class="mt-3 divide-y divide-base-300">
          <.danger_action
            title={gettext("Reboot")}
            description={gettext("Available when the device is online.")}
          >
            <button type="button" class="btn btn-sm" disabled>{gettext("Reboot")}</button>
          </.danger_action>
          <.danger_action
            title={gettext("Revoke")}
            description={
              gettext(
                "The device certificate stops being accepted. The device stays in the list with its journal and can send a new request."
              )
            }
          >
            <button
              type="button"
              class="btn btn-sm btn-error btn-outline"
              id="revoke"
              disabled={@device.status != :approved}
              phx-click="revoke"
              data-confirm={
                gettext(
                  "Revoke %{name}? It will disconnect and will not be able to reconnect without a new approval.",
                  name: @device.name
                )
              }
            >
              {gettext("Revoke")}
            </button>
          </.danger_action>
          <.danger_action
            title={gettext("Delete")}
            description={gettext("Only a revoked device can be deleted. The journal is deleted too.")}
          >
            <button
              type="button"
              class="btn btn-sm btn-error"
              id="delete"
              disabled={@device.status != :revoked}
              phx-click="delete"
              data-confirm={
                gettext("Delete %{name} and its journal permanently?", name: @device.name)
              }
            >
              {gettext("Delete")}
            </button>
          </.danger_action>
        </div>
      </div>
    </section>
    """
  end

  attr :title, :string, required: true
  attr :note, :string, default: nil
  slot :inner_block, required: true

  defp card(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-100 p-4">
      <div class="mb-3 flex items-center justify-between gap-2">
        <h2 class="font-semibold">{@title}</h2>
        <span :if={@note} class="badge badge-ghost badge-sm">{@note}</span>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :title, :string, required: true
  attr :description, :string, required: true
  slot :inner_block, required: true

  defp danger_action(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-3 py-3">
      <div class="max-w-xl">
        <p class="font-medium">{@title}</p>
        <p class="text-sm text-base-content/60">{@description}</p>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :device, :map, required: true
  attr :online, :map, default: nil

  defp info_tab(assigns) do
    ~H"""
    <section class="rounded-box border border-base-300 bg-base-100" id="info">
      <dl class="divide-y divide-base-300">
        <.info_row label={gettext("Status")}><.status_badge status={@device.status} /></.info_row>
        <.info_row label={gettext("Device ID (MAC)")}>
          <span class="font-mono">{Fleet.format_mac(@device.device_id)}</span>
        </.info_row>
        <.info_row label={gettext("Device code")}><.code code={@device.device_code} /></.info_row>
        <.info_row label={gettext("Connection")}>
          <.presence device={@device} online={@online} />
        </.info_row>
        <.info_row :if={@online} label={gettext("Connected since")}>
          <.time at={@online[:connected_at]} format="relative" id="info-connected" />
        </.info_row>
        <.info_row :if={@online && @online[:rssi]} label={gettext("Wi-Fi signal")}>
          {@online[:rssi]} dBm <.signal rssi={@online[:rssi]} />
        </.info_row>
        <.info_row :if={@online && @online[:uptime]} label={gettext("Uptime")}>
          {format_uptime(@online[:uptime])}
        </.info_row>
        <.info_row label={gettext("IP address")}>{@device.last_ip || "—"}</.info_row>
        <.info_row label={gettext("Firmware")}>{@device.firmware_version || "—"}</.info_row>
        <.info_row label={gettext("Last seen")}>
          <.time :if={@device.last_seen_at} at={@device.last_seen_at} id="info-seen" />
          <span :if={!@device.last_seen_at}>{gettext("never")}</span>
        </.info_row>
        <.info_row label={gettext("Request sent")}>
          <.time at={@device.requested_at} id="info-requested" />
        </.info_row>
        <.info_row :if={@device.approved_at} label={gettext("Approved")}>
          <.time at={@device.approved_at} id="info-approved" />
        </.info_row>
        <.info_row :if={@device.revoked_at} label={gettext("Revoked")}>
          <.time at={@device.revoked_at} id="info-revoked" />
        </.info_row>
        <.info_row :if={@device.certificate_serial} label={gettext("Certificate serial")}>
          <span class="font-mono text-xs break-all">{@device.certificate_serial}</span>
        </.info_row>
        <.info_row :if={@device.certificate_not_after} label={gettext("Certificate valid until")}>
          <.time at={@device.certificate_not_after} id="info-cert-until" />
        </.info_row>
      </dl>
    </section>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp info_row(assigns) do
    ~H"""
    <div class="grid gap-1 px-4 py-3 sm:grid-cols-[14rem_1fr]">
      <dt class="text-sm text-base-content/60">{@label}</dt>
      <dd class="text-sm">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :events, :list, required: true

  defp journal_tab(assigns) do
    ~H"""
    <section class="rounded-box border border-base-300 bg-base-100" id="journal">
      <p :if={@events == []} class="px-4 py-6 text-sm text-base-content/50">
        {gettext("No events yet")}
      </p>
      <ol :if={@events != []} class="divide-y divide-base-300">
        <li :for={event <- @events} id={"event-#{event.id}"} class="flex items-start gap-3 px-4 py-3">
          <span class="mt-0.5 grid size-7 shrink-0 place-items-center rounded-full bg-base-200">
            <.icon name={event_icon(event.type)} class="size-4" />
          </span>
          <p class="flex-1 text-sm">{event_text(event)}</p>
          <span class="shrink-0 text-xs text-base-content/50"><.time
            at={event.at}
            id={"event-at-#{event.id}"}
          /></span>
        </li>
      </ol>
    </section>
    """
  end

  defp format_uptime(seconds) do
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3600)
    minutes = div(rem(seconds, 3600), 60)

    cond do
      days > 0 -> gettext("%{d} d %{h} h", d: days, h: hours)
      hours > 0 -> gettext("%{h} h %{m} min", h: hours, m: minutes)
      true -> gettext("%{m} min", m: minutes)
    end
  end

  defp tab_path(device, :console), do: ~p"/devices/#{device.id}"
  defp tab_path(device, :settings), do: ~p"/devices/#{device.id}/settings"
  defp tab_path(device, :info), do: ~p"/devices/#{device.id}/info"
  defp tab_path(device, :journal), do: ~p"/devices/#{device.id}/journal"

  defp tab_title(:console), do: gettext("Console")
  defp tab_title(:settings), do: gettext("Settings")
  defp tab_title(:info), do: gettext("Details")
  defp tab_title(:journal), do: gettext("Journal")

  defp tab_icon(:console), do: "hero-command-line"
  defp tab_icon(:settings), do: "hero-cog-6-tooth"
  defp tab_icon(:info), do: "hero-information-circle"
  defp tab_icon(:journal), do: "hero-clock"

  defp event_icon(:requested), do: "hero-inbox-arrow-down"
  defp event_icon(:approved), do: "hero-check-badge"
  defp event_icon(:rejected), do: "hero-x-circle"
  defp event_icon(:revoked), do: "hero-no-symbol"
  defp event_icon(:renamed), do: "hero-pencil"
  defp event_icon(:moved), do: "hero-folder"
  defp event_icon(:connected), do: "hero-signal"
  defp event_icon(:disconnected), do: "hero-signal-slash"
  defp event_icon(type) when type in [:console_taken, :console_released], do: "hero-command-line"
  defp event_icon(:command), do: "hero-bolt"

  defp event_text(%{type: :requested, data: data}),
    do: gettext("Request received, device code %{code}", code: data["code"])

  defp event_text(%{type: :approved}), do: gettext("Approved, certificate issued")
  defp event_text(%{type: :rejected}), do: gettext("Request rejected")
  defp event_text(%{type: :revoked}), do: gettext("Revoked")

  defp event_text(%{type: :renamed, data: d}),
    do: gettext("Renamed from “%{from}” to “%{to}”", from: d["from"], to: d["to"])

  defp event_text(%{type: :moved, data: %{"folder" => nil}}), do: gettext("Moved out of folders")

  defp event_text(%{type: :moved, data: d}),
    do: gettext("Moved to folder “%{folder}”", folder: d["folder"])

  defp event_text(%{type: :connected}), do: gettext("Connected")
  defp event_text(%{type: :disconnected}), do: gettext("Disconnected")
  defp event_text(%{type: :console_taken}), do: gettext("Console taken")
  defp event_text(%{type: :console_released}), do: gettext("Console released")
  defp event_text(%{type: :command, data: d}), do: gettext("Command: %{op}", op: d["op"])
end
