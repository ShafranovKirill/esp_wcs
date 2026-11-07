defmodule BastionWeb.DeviceLive do
  use BastionWeb, :live_view

  alias Bastion.Console
  alias Bastion.Console.Domain.Sequence
  alias Bastion.Console.Events.{ConsoleTaken, LockChanged}
  alias Bastion.Fleet
  alias Bastion.Link.Events.{ConsoleOutput, PresenceChanged}

  @tabs [:console, :settings, :info, :journal]

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    case Fleet.fetch_device(socket.assigns.current_actor, id) do
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
           return_path: workspace_path(params["from"]),
           folders: Fleet.visible_folders(socket.assigns.current_actor).folders,
           online: Bastion.Link.presence(device.id),
           console: :idle,
           auto_baud: false,
           folder_query: "",
           folder_draft: device.folder_ids,
           journal_filter: "all",
           console_since: nil,
           sequence: nil,
           sequence_error: nil,
           sequence_form:
             to_form(%{"script" => "", "delay_ms" => "500", "ending" => "cr"}, as: :sequence)
         )
         |> assign_forms()
         |> assign_can()
         |> allow_upload(:command_file,
           accept: ~w(.txt .cfg .conf),
           max_entries: 1,
           max_file_size: 256 * 1024,
           auto_upload: true
         )}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    tab = socket.assigns.live_action

    socket =
      socket
      |> assign(auto_baud: if(tab == :console, do: socket.assigns.auto_baud, else: false))
      |> assign(tab: tab, page_title: "#{socket.assigns.device.name} · #{tab_title(tab)}")
      |> then(fn s ->
        if tab == :journal, do: assign(s, events: Fleet.list_events(s.assigns.device.id)), else: s
      end)
      |> sync_console()

    {:noreply, socket}
  end

  defp sync_console(socket) do
    socket = assign_can(socket)
    %{device: device, tab: tab, console: console} = socket.assigns
    wanted? = connected?(socket) and tab == :console and device.status == :approved

    cond do
      wanted? and not socket.assigns.can.console_write and socket.assigns.can.console_read ->
        if console == :reader do
          socket
        else
          socket = drop_console(socket)

          case Console.observe(socket.assigns.current_actor, device.id) do
            {:ok, history} ->
              socket
              |> assign(console: :reader)
              |> push_event("console-reset", %{data: Base.encode64(history)})
              |> push_event("console-state", %{owner: false})

            _ ->
              assign(socket, console: :forbidden)
          end
        end

      wanted? and not socket.assigns.can.console_write ->
        socket |> drop_console() |> assign(console: :forbidden)

      wanted? and console != :owner ->
        socket |> drop_console() |> attach_console()

      not wanted? and console == :owner ->
        release_console(socket)

      not wanted? ->
        socket |> drop_console() |> assign(console: :idle)

      true ->
        socket
    end
  end

  defp attach_console(socket) do
    case Console.attach(socket.assigns.current_actor, socket.assigns.device.id) do
      {:ok, history} -> owner(socket, history)
      {:busy, since} -> busy(socket, since)
      {:error, _} -> assign(socket, console: :forbidden)
    end
  end

  defp release_console(socket) do
    socket = stop_sequence(socket, :stopped)
    Console.release(socket.assigns.current_actor, socket.assigns.device.id)

    socket
    |> assign(console: :idle, auto_baud: false)
    |> push_event("console-state", %{owner: false})
  end

  defp drop_console(%{assigns: %{console: :owner}} = socket), do: release_console(socket)

  defp drop_console(%{assigns: %{console: :reader}} = socket) do
    Console.unobserve(socket.assigns.device.id)
    assign(socket, console: :idle)
  end

  defp drop_console(socket), do: socket

  defp assign_can(socket) do
    actor = socket.assigns.current_actor
    device = socket.assigns.device
    can = &Fleet.can?(actor, &1, device)

    assign(socket,
      can: %{
        approve: Bastion.Access.can?(actor, "enrollment.approve"),
        console_write: can.("console.write"),
        console_read: can.("console.read"),
        configure: can.("device.configure"),
        wifi: can.("device.wifi"),
        reboot: can.("device.reboot"),
        revoke: can.("device.revoke"),
        settings: Enum.any?(~w(device.configure device.wifi device.reboot device.revoke), can)
      }
    )
  end

  defp owner(socket, history) do
    socket
    |> assign(console: :owner, console_since: nil)
    |> push_event("console-reset", %{data: Base.encode64(history)})
    |> push_event("console-state", %{owner: socket.assigns.online != nil})
  end

  defp busy(socket, since) do
    socket = stop_sequence(socket, :stopped)

    socket
    |> assign(console: :busy, console_since: since, auto_baud: false)
    |> push_event("console-state", %{owner: false})
  end

  defp assign_forms(socket) do
    device = socket.assigns.device

    assign(socket,
      name_form: to_form(%{"name" => device.name}, as: :device),
      wifi_form: to_form(%{"ssid" => "", "password" => ""}, as: :wifi)
    )
  end

  defp reload(socket) do
    actor = socket.assigns.current_actor

    case Fleet.fetch_device(actor, socket.assigns.device.id) do
      nil ->
        socket
        |> drop_console()
        |> put_flash(:info, gettext("The device was deleted or you no longer have access to it"))
        |> push_navigate(to: ~p"/")

      device ->
        socket =
          socket
          |> assign(device: device, folders: Fleet.visible_folders(actor).folders)
          |> assign_forms()
          |> assign_can()

        if socket.assigns.tab == :journal,
          do: assign(socket, events: Fleet.list_events(device.id)),
          else: socket
    end
  end

  @impl true
  def handle_info(
        {:sequence_tick, id},
        %{assigns: %{sequence: %Sequence{id: id, status: :running}}} = socket
      ) do
    sequence = socket.assigns.sequence
    actor = Bastion.Access.actor(socket.assigns.current_user)

    case Console.send_sequence_line(actor, socket.assigns.device.id, Sequence.frame(sequence)) do
      :ok ->
        data = Sequence.frame(sequence)
        next = Sequence.advance(sequence)

        socket =
          socket
          |> assign(sequence: next)
          |> push_event("sequence-input", %{data: Base.encode64(data)})

        if next.sent == next.total do
          {:noreply, stop_sequence(socket, :completed)}
        else
          Process.send_after(self(), {:sequence_tick, id}, next.delay_ms)
          {:noreply, socket}
        end

      {:error, :backpressure} ->
        now = System.monotonic_time(:millisecond)
        waiting = sequence.waiting_since || now

        if now - waiting >= 30_000 do
          {:noreply,
           socket |> assign(sequence_error: :sequence_credit_timeout) |> stop_sequence(:stopped)}
        else
          Process.send_after(self(), {:sequence_tick, id}, 100)
          {:noreply, assign(socket, sequence: %{sequence | waiting_since: waiting})}
        end

      {:error, reason} ->
        {:noreply, socket |> assign(sequence_error: reason) |> stop_sequence(:stopped)}
    end
  end

  def handle_info({:sequence_tick, _}, socket), do: {:noreply, socket}

  def handle_info(
        {:event, %PresenceChanged{id: id}},
        %{assigns: %{device: %{id: id}}} = socket
      ) do
    online = Bastion.Link.presence(id)
    socket = if online, do: socket, else: stop_sequence(socket, :stopped)

    {:noreply,
     socket
     |> assign(online: online)
     |> push_event("console-state", %{owner: socket.assigns.console == :owner and online != nil})}
  end

  def handle_info({:event, %PresenceChanged{}}, socket), do: {:noreply, socket}

  def handle_info({:event, %ConsoleOutput{data: data}}, %{assigns: %{console: mode}} = socket)
      when mode in [:owner, :reader],
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
  def handle_event(event, _, %{assigns: %{sequence: %Sequence{status: :running}}} = socket)
      when event in ["console-probe", "console-probe-end"] do
    {:reply, %{ok: false, error: gettext("Stop the command sequence first")}, socket}
  end

  def handle_event(event, _, %{assigns: %{sequence: %Sequence{status: :running}}} = socket)
      when event in [
             "console-input",
             "console-line",
             "console-profile",
             "console-break",
             "sequence-preview",
             "sequence-start"
           ] do
    {:noreply, socket}
  end

  def handle_event(
        "sequence-file",
        _,
        %{assigns: %{sequence: %Sequence{status: :running}}} = socket
      ),
      do: {:noreply, socket}

  def handle_event("sequence-file", _, socket),
    do: {:noreply, assign(socket, sequence: nil, sequence_error: nil)}

  def handle_event("sequence-file-cancel", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :command_file, ref)}

  def handle_event("sequence-preview", %{"sequence" => params}, socket) do
    with :ok <-
           Fleet.authorize(
             socket.assigns.current_actor,
             "console.write",
             socket.assigns.device.id
           ),
         {:ok, text, socket} <- sequence_text(socket, params["script"] || ""),
         {:ok, sequence} <- Console.prepare_sequence(text, params) do
      {:noreply,
       assign(socket,
         sequence: sequence,
         sequence_error: nil,
         sequence_form: to_form(Map.put(params, "script", text), as: :sequence)
       )}
    else
      {:error, reason} -> {:noreply, assign(socket, sequence_error: reason, sequence: nil)}
    end
  end

  def handle_event(
        "sequence-start",
        %{"id" => id},
        %{assigns: %{sequence: %Sequence{id: id, status: :ready}}} = socket
      ) do
    case sequence_allowed(socket) do
      :ok ->
        sequence = %{socket.assigns.sequence | status: :running}

        :ok =
          Fleet.record_event(
            socket.assigns.device.id,
            :command,
            Sequence.audit(sequence),
            socket.assigns.current_actor
          )

        send(self(), {:sequence_tick, id})

        {:noreply,
         socket
         |> assign(sequence: sequence, sequence_error: nil)
         |> push_event("sequence-state", %{running: true})}

      {:error, reason} ->
        {:noreply, assign(socket, sequence_error: reason)}
    end
  end

  def handle_event("sequence-start", _, socket), do: {:noreply, socket}

  def handle_event("sequence-stop", _, socket), do: {:noreply, stop_sequence(socket, :stopped)}

  def handle_event("sequence-clear", _, socket) do
    socket = stop_sequence(socket, :stopped)

    {:noreply,
     assign(socket,
       sequence: nil,
       sequence_error: nil,
       sequence_form:
         to_form(%{"script" => "", "delay_ms" => "500", "ending" => "cr"}, as: :sequence)
     )}
  end

  def handle_event("console-input", %{"data" => data}, %{assigns: %{console: :owner}} = socket)
      when is_binary(data) do
    if Fleet.can?(socket.assigns.current_actor, "console.write", socket.assigns.device),
      do: Console.input(socket.assigns.device.id, data)

    {:noreply, socket}
  end

  def handle_event("console-input", _params, socket), do: {:noreply, socket}

  def handle_event("console-ping", _params, socket), do: {:noreply, socket}

  def handle_event("console-take", _params, socket) do
    case Console.take(socket.assigns.current_actor, socket.assigns.device.id) do
      {:ok, history} -> {:noreply, owner(socket, history)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, BastionWeb.Errors.message(reason))}
    end
  end

  def handle_event("console-break", _params, %{assigns: %{console: :owner}} = socket) do
    id = socket.assigns.device.id
    actor = socket.assigns.current_actor
    lv = self()
    {:noreply, start_async(socket, :console_break, fn -> Console.send_break(actor, id, lv) end)}
  end

  def handle_event("console-break", _params, socket), do: {:noreply, socket}

  def handle_event("console-line", _params, %{assigns: %{auto_baud: true}} = socket),
    do: {:noreply, socket}

  def handle_event("console-line", %{"line" => params}, socket) do
    id = socket.assigns.device.id
    actor = socket.assigns.current_actor
    {:noreply, start_async(socket, :console_line, fn -> Console.configure(actor, id, params) end)}
  end

  def handle_event("console-profile", %{"profile" => profile}, socket) do
    if socket.assigns.auto_baud || socket.assigns.console != :owner do
      {:noreply, socket}
    else
      actor = socket.assigns.current_actor
      id = socket.assigns.device.id

      {:noreply,
       start_async(socket, :console_profile, fn -> Console.apply_profile(actor, id, profile) end)}
    end
  end

  def handle_event("console-probe", %{"line" => line}, socket) do
    result = Console.probe(socket.assigns.current_actor, socket.assigns.device.id, line)

    case result do
      :ok -> {:reply, %{ok: true}, assign(socket, auto_baud: true)}
      {:error, reason} -> {:reply, %{ok: false, error: BastionWeb.Errors.message(reason)}, socket}
    end
  end

  def handle_event("console-probe-end", _params, socket) do
    result = Console.end_probe(socket.assigns.current_actor, socket.assigns.device.id)
    {:reply, %{ok: result == :ok}, assign(socket, auto_baud: false)}
  end

  def handle_event("rename", %{"device" => %{"name" => name}}, socket) do
    case Fleet.rename(socket.assigns.current_actor, socket.assigns.device.id, name) do
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

  def handle_event("folder-search", %{"q" => query}, socket),
    do: {:noreply, assign(socket, folder_query: String.slice(query, 0, 120))}

  def handle_event("folder-toggle", %{"id" => id}, socket) do
    draft = socket.assigns.folder_draft
    visible = Enum.any?(socket.assigns.folders, &(&1.id == id))

    if socket.assigns.can.configure and visible do
      ids = if id in draft, do: List.delete(draft, id), else: Enum.uniq([id | draft])
      {:noreply, assign(socket, folder_draft: ids)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("folder-cancel", _, socket),
    do:
      {:noreply, assign(socket, folder_draft: socket.assigns.device.folder_ids, folder_query: "")}

  def handle_event("journal-filter", %{"type" => type}, socket),
    do: {:noreply, assign(socket, journal_filter: type)}

  def handle_event("set-folders", _params, socket) do
    ids = socket.assigns.folder_draft

    case Fleet.set_folders(socket.assigns.current_actor, socket.assigns.device.id, ids) do
      {:ok, _} -> {:noreply, socket |> reload() |> put_flash(:info, gettext("Folders changed"))}
      {:error, reason} -> {:noreply, put_flash(socket, :error, BastionWeb.Errors.message(reason))}
    end
  end

  def handle_event("approve", %{"code" => code}, socket),
    do: lifecycle(socket, &Fleet.approve(&1, &2, code), gettext("Device approved"))

  def handle_event("reject", _params, socket),
    do: lifecycle(socket, &Fleet.reject/2, gettext("Request rejected"))

  def handle_event("revoke", _params, socket),
    do: lifecycle(socket, &Fleet.revoke/2, gettext("Device revoked"))

  def handle_event("reboot", _params, socket) do
    id = socket.assigns.device.id
    actor = socket.assigns.current_actor
    {:noreply, start_async(socket, :reboot, fn -> Bastion.Control.reboot(actor, id) end)}
  end

  def handle_event("wifi", %{"wifi" => params}, socket) do
    id = socket.assigns.device.id
    actor = socket.assigns.current_actor
    params = Map.take(params, ["ssid", "password"])

    socket =
      socket
      |> assign(wifi_form: to_form(Map.put(params, "password", ""), as: :wifi))
      |> start_async(:wifi, fn -> Bastion.Control.set_wifi(actor, id, params) end)

    {:noreply, socket}
  end

  def handle_event("delete", _params, socket) do
    case Fleet.delete(socket.assigns.current_actor, socket.assigns.device.id) do
      {:ok, :deleted} ->
        {:noreply,
         socket |> put_flash(:info, gettext("Device deleted")) |> push_navigate(to: ~p"/")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, BastionWeb.Errors.message(reason))}
    end
  end

  defp sequence_allowed(socket) do
    cond do
      socket.assigns.console != :owner ->
        {:error, :not_owner}

      is_nil(socket.assigns.online) ->
        {:error, :offline}

      socket.assigns.auto_baud ->
        {:error, :sequence_busy}

      not Enum.all?(~w(console credit), &(&1 in Map.get(socket.assigns.online, :caps, []))) ->
        {:error, :sequence_no_credit}

      not Fleet.can?(socket.assigns.current_actor, "console.write", socket.assigns.device) ->
        {:error, :forbidden}

      true ->
        :ok
    end
  end

  defp sequence_text(socket, text) when is_binary(text) do
    {complete, pending} = uploaded_entries(socket, :command_file)

    cond do
      pending != [] ->
        {:error, :sequence_upload_pending}

      complete != [] and String.trim(text) != "" ->
        {:error, :sequence_choose_source}

      complete != [] ->
        [text] =
          consume_uploaded_entries(socket, :command_file, fn %{path: path}, _ ->
            {:ok, File.read!(path)}
          end)

        {:ok, text, socket}

      true ->
        {:ok, text, socket}
    end
  end

  defp sequence_text(_, _), do: {:error, :sequence_invalid_text}

  defp stop_sequence(
         %{assigns: %{sequence: %Sequence{status: :running} = sequence}} = socket,
         status
       ) do
    sequence = Sequence.finish(sequence, status)

    Fleet.record_event(
      socket.assigns.device.id,
      :command,
      Sequence.audit(sequence),
      socket.assigns.current_actor
    )

    socket |> assign(sequence: sequence) |> push_event("sequence-state", %{running: false})
  end

  defp stop_sequence(socket, _), do: socket

  @impl true
  def handle_async(:console_profile, {:ok, {:ok, profile}}, socket) do
    {:noreply,
     socket
     |> push_event("terminal-profile", %{
       id: profile.id,
       label: "#{profile.vendor} #{profile.model}",
       backspace: profile.backspace
     })
     |> put_flash(:info, gettext("Device profile applied"))}
  end

  def handle_async(op, {:ok, :ok}, socket), do: {:noreply, put_flash(socket, :info, done(op))}

  def handle_async(_op, {:ok, {:error, reason}}, socket),
    do: {:noreply, put_flash(socket, :error, BastionWeb.Errors.message(reason))}

  def handle_async(_op, {:exit, _reason}, socket),
    do: {:noreply, put_flash(socket, :error, BastionWeb.Errors.message(:failed))}

  defp done(:console_break), do: gettext("BREAK sent")
  defp done(:console_line), do: gettext("Port settings applied")
  defp done(:reboot), do: gettext("The device is rebooting")
  defp done(:wifi), do: gettext("The device saved the new network and is rebooting")

  defp lifecycle(socket, fun, success) do
    socket = push_event(socket, "close-dialog", %{id: "approve-dialog"})

    case fun.(socket.assigns.current_actor, socket.assigns.device.id) do
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
      current_user={@current_user}
      current_actor={@current_actor}
      locale={@locale}
      current_path={@current_path}
    >
      <.link
        navigate={@return_path}
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
        <div :if={@can.approve} class="flex gap-2">
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
          :if={tab != :settings or @can.settings}
          patch={tab_path(@device, tab, @return_path)}
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
        auto_baud={@auto_baud}
        sequence={@sequence}
        sequence_error={@sequence_error}
        sequence_form={@sequence_form}
        command_upload={@uploads.command_file}
        can={@can}
      />
      <.settings_tab
        :if={@tab == :settings and @can.settings}
        folder_query={@folder_query}
        folder_draft={@folder_draft}
        can={@can}
        device={@device}
        online={@online}
        wifi_form={@wifi_form}
        name_form={@name_form}
        folders={@folders}
      />
      <.info_tab :if={@tab == :info} device={@device} online={@online} />
      <.journal_tab :if={@tab == :journal} events={@events} filter={@journal_filter} />

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
  attr :auto_baud, :boolean, default: false
  attr :can, :map, required: true

  attr :sequence, :any, default: nil
  attr :sequence_error, :any, default: nil
  attr :sequence_form, :map, required: true
  attr :command_upload, :any, required: true

  defp console_tab(assigns) do
    line = assigns.online && assigns.online[:console]

    assigns =
      assign(assigns, :sequence_running, match?(%Sequence{status: :running}, assigns.sequence))

    assigns =
      assign(assigns,
        line: line,
        line_form: to_form(line_params(line), as: :line)
      )

    ~H"""
    <section class="space-y-3" id="console">
      <div
        :if={@console == :reader}
        id="console-readonly"
        class="flex items-center gap-2 rounded-lg border border-base-300 bg-base-100 px-4 py-3 text-sm"
      >
        <.icon name="hero-eye" class="size-4" />{gettext(
          "Read-only console. Another operator may control this device."
        )}
      </div>
      <.form
        for={@line_form}
        id="console-line"
        phx-submit="console-line"
        class="flex flex-wrap items-center gap-2"
      >
        <.line_fields
          form={@line_form}
          disabled={!@online or !@can.configure or @auto_baud or @sequence_running}
        />
        <button
          type="submit"
          id="console-line-apply"
          class="btn btn-sm btn-primary"
          disabled={!@online or !@can.configure or @auto_baud or @sequence_running}
        >{gettext("Apply")}</button>
        <span :if={@line} class="text-sm text-base-content/50" id="console-line-current">
          {Console.format_line(@line)}
        </span>
        <span class="flex-1"></span>
        <button
          type="button"
          class="btn btn-sm"
          id="console-break"
          phx-click="console-break"
          disabled={@console != :owner or !@online or @sequence_running}
          title={gettext("Send BREAK")}
        >
          <.icon name="hero-bolt" class="size-4" /> BREAK
        </button>
      </.form>

      <div class="flex flex-wrap items-start gap-3 rounded-box border border-base-300 p-3">
        <details id="console-profiles" class="min-w-48">
          <summary class="cursor-pointer font-medium">{gettext("Device profiles")}</summary>
          <details class="ml-3 mt-2">
            <summary class="cursor-pointer">Eltex</summary>
            <details :for={family <- ["MES", "ESR"]} class="ml-3 mt-2">
              <summary class="cursor-pointer">{family}</summary>
              <button
                :for={profile <- Enum.filter(Console.profiles(), &(&1.family == family))}
                id={"profile-#{profile.id}"}
                type="button"
                phx-click="console-profile"
                phx-value-profile={profile.id}
                disabled={
                  !@online or !@can.configure or @console != :owner or @auto_baud or @sequence_running
                }
                class="btn btn-sm btn-ghost mt-1"
              >{profile.model} · 115200 8N1 · BS</button>
            </details>
          </details>
        </details>
        <div
          id="console-keyboard-preferences"
          phx-update="ignore"
          class="flex flex-wrap items-center gap-3"
        >
          <label class="text-sm">
            Backspace
            <select id="console-backspace" class="select select-sm w-44" aria-label="Backspace">
              <option value="del">DEL (0x7F)</option>
              <option value="bs">BS / Ctrl+H (0x08)</option>
            </select>
          </label>
          <span id="console-profile-name" class="text-sm text-base-content/60"></span>
        </div>
        <button
          id="console-autobaud"
          type="button"
          class="btn btn-sm btn-outline"
          disabled={
            !@online or !@can.configure or @console != :owner or @auto_baud or @sequence_running
          }
          phx-click={JS.dispatch("wcs:autobaud", to: "#terminal-#{@device.id}")}
        >{gettext("Detect baud rate")}</button>
      </div>
      <div id="console-detection" phx-update="ignore" class="space-y-2" aria-live="polite"></div>

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
        :if={@console == :forbidden}
        id="console-forbidden"
        class="alert alert-soft"
      >
        <.icon name="hero-lock-closed" class="size-6" />
        <span>{gettext("You do not have the right to control this console.")}</span>
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

      <div class="flex flex-wrap items-center justify-between gap-3 text-sm">
        <span class="inline-flex items-center gap-2 text-base-content/65">
          <.icon name="hero-command-line" class="size-4" />
          {if @console == :owner and @online,
            do: gettext("Controlling console"),
            else: gettext("Console preview")}
        </span>
        <div class="flex gap-2">
          <button
            type="button"
            class="btn btn-sm btn-ghost"
            id="terminal-download"
            phx-click={JS.dispatch("wcs:terminal-download", to: "#terminal-#{@device.id}")}
          >
            <.icon name="hero-arrow-down-tray" class="size-4" />{gettext("Download visible history")}
          </button>
          <button
            type="button"
            class="btn btn-sm btn-ghost"
            id="terminal-fullscreen"
            phx-click={JS.dispatch("wcs:terminal-fullscreen", to: "#terminal-#{@device.id}")}
          >
            <.icon name="hero-arrows-pointing-out" class="size-4" />{gettext("Full screen")}
          </button>
        </div>
      </div>
      <.sequence_panel
        sequence={@sequence}
        can_prepare={@can.console_write}
        error={@sequence_error}
        form={@sequence_form}
        upload={@command_upload}
        disabled={@console != :owner or !@online or @auto_baud}
      />
      <details class="rounded-lg border border-base-300 bg-base-100 p-3" id="terminal-recording-panel">
        <summary class="cursor-pointer text-sm font-medium">{gettext("Session recording")}</summary>
        <p class="mt-3 max-w-3xl text-xs leading-relaxed text-base-content/65">
          {gettext(
            "Records this tab's input and output with timestamps. May contain passwords. Kept only in this tab until downloaded; leaving the console clears it. Input does not confirm command execution. Recording stops at 2 MB."
          )}
        </p>
        <div
          id="terminal-recording-controls"
          phx-update="ignore"
          class="mt-3 flex flex-wrap items-center gap-3"
        >
          <button
            id="terminal-record"
            type="button"
            class="btn btn-sm btn-outline"
            data-start={gettext("Start recording")}
            data-stop={gettext("Stop recording")}
          >{gettext("Start recording")}</button>
          <button id="terminal-record-export" type="button" class="btn btn-sm btn-ghost" disabled>{gettext(
            "Download session JSON"
          )}</button>
          <span
            id="terminal-record-status"
            class="text-xs text-base-content/65"
            aria-live="polite"
            data-recording={gettext("Recording in this tab")}
            data-stopped={gettext("Recording stopped")}
            data-limit={
              gettext("Recording limit reached. Download the session before starting again.")
            }
          ></span>
        </div>
      </details>
      <div class="terminal-frame">
        <div
          id={"terminal-#{@device.id}"}
          phx-hook="Terminal"
          phx-update="ignore"
          data-readonly="true"
          data-device-id={@device.id}
          data-tools-labels={
            JSON.encode!(%{
              listening: gettext("Listening at"),
              no_data:
                gettext(
                  "No reliable output detected. The original port settings have been restored. Start output on the connected device and try again."
                ),
              probable: gettext("Possible baud rate. Review the sample before applying."),
              apply: gettext("Apply baud rate"),
              cancel: gettext("Cancel"),
              cancelled: gettext("Detection cancelled. Original port settings restored."),
              passive:
                gettext(
                  "Detection listens only: it sends no Enter or commands. Start output on the connected device. Format: 8N1."
                ),
              restore_failed:
                gettext(
                  "Could not confirm restoration. The device restores temporary settings automatically after six seconds."
                ),
              failed: gettext("Could not detect the baud rate"),
              saved: gettext("Saved in this browser for this device")
            })
          }
          class="size-full overflow-hidden"
        >
        </div>
      </div>
    </section>
    """
  end

  attr :sequence, :any, default: nil
  attr :error, :any, default: nil
  attr :form, :map, required: true
  attr :upload, :any, required: true
  attr :disabled, :boolean, default: false

  attr :can_prepare, :boolean, default: false

  defp sequence_panel(assigns) do
    assigns = assign(assigns, :running, match?(%Sequence{status: :running}, assigns.sequence))

    ~H"""
    <details id="configuration-panel" class="workspace-panel">
      <summary class="cursor-pointer text-sm font-semibold">{gettext("Send configuration")}</summary>
      <div class="mt-4 space-y-4">
        <p class="max-w-3xl text-sm leading-relaxed text-base-content/65">
          {gettext(
            "Paste commands or upload a UTF-8 .txt, .cfg or .conf file. Each line is sent followed by Enter. Review the device prompt first. The interval does not wait for a command result; interactive questions require manual control."
          )}
        </p>
        <.form
          for={@form}
          id="sequence-form"
          phx-submit="sequence-preview"
          phx-change="sequence-file"
          class="space-y-3"
        >
          <.input
            field={@form[:script]}
            type="textarea"
            label={gettext("Commands, one per line")}
            class="textarea min-h-40 w-full font-mono text-sm"
            maxlength="262144"
            disabled={@running}
          />
          <div class="flex flex-wrap items-end gap-4">
            <div class="min-w-0 flex-1">
              <label for={@upload.ref} class="mb-2 block text-sm font-medium">{gettext(
                "Or choose a configuration file"
              )}</label>
              <.live_file_input upload={@upload} disabled={@running} class="block w-full text-sm" />
            </div>
            <.input
              field={@form[:delay_ms]}
              type="number"
              min="50"
              max="5000"
              label={gettext("Interval between lines, ms")}
              disabled={@running}
            />
            <.input
              field={@form[:ending]}
              type="select"
              label={gettext("Enter format")}
              options={[{"CR", "cr"}, {"CRLF", "crlf"}, {"LF", "lf"}]}
              disabled={@running}
            />
          </div>
          <div :for={entry <- @upload.entries} class="flex flex-wrap items-center gap-3 text-sm">
            <span>{entry.client_name} · {entry.progress}%</span>
            <button
              type="button"
              phx-click="sequence-file-cancel"
              phx-value-ref={entry.ref}
              disabled={@running}
              class="btn btn-xs btn-ghost"
            >{gettext("Remove")}</button>
            <span :for={_error <- upload_errors(@upload, entry)} class="text-error">{gettext(
              "Use a UTF-8 text file up to 256 KB"
            )}</span>
          </div>
          <div class="flex gap-2">
            <button
              type="submit"
              id="sequence-preview"
              class="btn btn-sm"
              disabled={!@can_prepare or @running}
            >{gettext("Review commands")}</button>
            <button
              type="button"
              phx-click="sequence-clear"
              class="btn btn-sm btn-ghost"
              disabled={@running}
            >{gettext("Clear")}</button>
          </div>
        </.form>
        <p :if={@error} id="sequence-error" class="text-sm text-error" role="alert">
          {BastionWeb.Errors.message(@error)}
        </p>
        <div
          :if={@sequence}
          id="sequence-progress"
          class="space-y-3 rounded-lg border border-base-300 p-4"
          aria-live="polite"
        >
          <div class="flex flex-wrap items-center justify-between gap-3">
            <p class="font-medium">{sequence_status(@sequence.status)}</p>
            <span class="text-sm tabular-nums">{gettext("%{sent} / %{total} lines sent",
              sent: @sequence.sent,
              total: @sequence.total
            )}</span>
          </div>
          <progress
            class="progress progress-primary w-full"
            value={@sequence.sent}
            max={@sequence.total}
          ></progress>
          <p class="text-xs text-base-content/60">
            {gettext(
              "Sending is not proof of execution. Stop prevents the next lines; commands already sent cannot be undone. Leaving this console stops the sequence. The activity journal stores counts and a checksum, not command text."
            )}
          </p>
          <ol
            :if={@sequence.status == :ready}
            class="max-h-56 list-inside list-decimal overflow-auto rounded bg-base-200 p-3 font-mono text-xs leading-6"
          >
            <li :for={line <- @sequence.lines} class="whitespace-pre-wrap break-all">
              {if line == "", do: gettext("[empty line]"), else: line}
            </li>
          </ol>
          <button
            :if={@sequence.status == :ready}
            type="button"
            id="sequence-start"
            phx-click="sequence-start"
            phx-value-id={@sequence.id}
            disabled={@disabled}
            class="btn btn-sm btn-primary"
          >{gettext("Start sending")}</button>
          <button
            :if={@running}
            type="button"
            id="sequence-stop"
            phx-click="sequence-stop"
            class="btn btn-sm btn-warning"
          >{gettext("Stop sending")}</button>
        </div>
      </div>
    </details>
    """
  end

  defp sequence_status(:ready), do: gettext("Ready for review")
  defp sequence_status(:running), do: gettext("Sending configuration")
  defp sequence_status(:completed), do: gettext("All lines sent. Check the terminal output.")
  defp sequence_status(:stopped), do: gettext("Sending stopped")

  attr :form, :map, required: true
  attr :disabled, :boolean, default: false
  attr :class, :string, default: "select select-sm"

  defp line_fields(assigns) do
    ~H"""
    <select
      name="line[baud]"
      class={[@class, "w-32"]}
      disabled={@disabled}
      aria-label={gettext("Baud rate")}
    >
      <option
        :for={baud <- Console.bauds()}
        value={baud}
        selected={@form[:baud].value == baud}
      >
        {baud}
      </option>
    </select>
    <select
      name="line[data_bits]"
      class={[@class, "w-20"]}
      disabled={@disabled}
      aria-label={gettext("Data bits")}
    >
      <option :for={bits <- 8..5//-1} value={bits} selected={@form[:data_bits].value == bits}>
        {bits}
      </option>
    </select>
    <select
      name="line[parity]"
      class={[@class, "w-28"]}
      disabled={@disabled}
      aria-label={gettext("Parity")}
    >
      <option
        :for={{label, value} <- parity_options()}
        value={value}
        selected={@form[:parity].value == value}
      >
        {label}
      </option>
    </select>
    <select
      name="line[stop_bits]"
      class={[@class, "w-20"]}
      disabled={@disabled}
      aria-label={gettext("Stop bits")}
    >
      <option :for={stop <- [1, 2]} value={stop} selected={@form[:stop_bits].value == stop}>
        {stop}
      </option>
    </select>
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
  attr :online, :map, default: nil
  attr :name_form, :map, required: true
  attr :wifi_form, :map, required: true
  attr :folders, :list, required: true
  attr :folder_query, :string, required: true
  attr :folder_draft, :list, required: true
  attr :can, :map, required: true

  defp settings_tab(assigns) do
    line = assigns.online && assigns.online[:console]
    by_id = Map.new(assigns.folders, &{&1.id, &1})
    options = Enum.map(assigns.folders, &{Fleet.Folder.full_name(&1, by_id), &1.id})
    query = String.downcase(String.trim(assigns.folder_query))

    results =
      if query == "",
        do: [],
        else:
          Enum.filter(options, fn {name, _} -> String.contains?(String.downcase(name), query) end)

    assigns =
      assign(assigns,
        line_form: to_form(line_params(line), as: :line),
        folder_options: Map.new(options, fn {name, id} -> {id, name} end),
        folder_results: Enum.take(results, 20),
        folder_result_count: length(results)
      )

    ~H"""
    <section class="grid items-start gap-6 lg:grid-cols-2" id="settings">
      <div class="min-w-0 space-y-6">
        <.card :if={@can.configure} title={gettext("Name")}>
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
        <.card
          :if={@can.configure}
          title={gettext("Console port")}
          note={!@online && gettext("Available when the device is online")}
        >
          <.form
            for={@line_form}
            id="settings-line"
            phx-submit="console-line"
            class="flex flex-wrap items-center gap-2"
          >
            <.line_fields form={@line_form} disabled={!@online} />
            <button
              type="submit"
              id="settings-line-apply"
              class="btn btn-sm btn-primary"
              disabled={!@online}
            >{gettext("Apply")}</button>
          </.form>
        </.card>
      </div>
      <div class="min-w-0 space-y-6">
        <.card :if={@can.configure} title={gettext("Folders")}>
          <p :if={@folders == []} class="text-sm text-base-content/60">
            {gettext("No folders yet — create them on the devices page")}
          </p>
          <div id="folder-picker" class="space-y-4">
            <div id="folder-selected" class="space-y-2">
              <p :if={@folder_draft == []} class="text-sm text-base-content/60">
                {gettext("No folders selected")}
              </p>
              <button
                :for={id <- @folder_draft}
                id={"folder-selected-#{id}"}
                type="button"
                phx-click="folder-toggle"
                phx-value-id={id}
                class="folder-result"
              >
                <.icon name="hero-folder" class="size-4 shrink-0 text-primary" />
                <span class="flex-1">{Map.get(@folder_options, id, id)}</span>
                <.icon name="hero-x-mark" class="size-4 shrink-0" />
                <span class="sr-only">{gettext("Remove")}</span>
              </button>
            </div>
            <form id="folder-search" phx-change="folder-search" phx-submit="folder-search">
              <label class="text-sm font-medium" for="folder-query">{gettext("Find a folder")}</label>
              <input
                id="folder-query"
                name="q"
                type="search"
                value={@folder_query}
                phx-debounce="250"
                class="input mt-2 w-full"
                placeholder={gettext("Search by folder name or path")}
                autocomplete="off"
              />
            </form>
            <div
              :if={@folder_query != ""}
              id="folder-results"
              class="max-h-64 space-y-2 overflow-y-auto"
              aria-live="polite"
            >
              <p :if={@folder_result_count == 0} class="text-sm text-base-content/60">
                {gettext("No matching folders")}
              </p>
              <button
                :for={{name, id} <- @folder_results}
                id={"folder-option-#{id}"}
                type="button"
                phx-click="folder-toggle"
                phx-value-id={id}
                class="folder-result"
                aria-pressed={to_string(id in @folder_draft)}
              >
                <.icon
                  name={if id in @folder_draft, do: "hero-check-circle", else: "hero-plus-circle"}
                  class="size-4 shrink-0 text-primary"
                />
                <span>{name}</span>
              </button>
              <p :if={@folder_result_count > 20} class="text-xs text-base-content/60">
                {gettext("Showing the first 20 matches. Refine your search.")}
              </p>
            </div>
            <p class="text-xs leading-relaxed text-base-content/60">
              {gettext("A device can be in several folders; access is granted through any of them.")}
            </p>
            <form id="folder-form" phx-submit="set-folders" class="flex gap-2">
              <button
                type="submit"
                id="folder-save"
                disabled={MapSet.new(@folder_draft) == MapSet.new(@device.folder_ids)}
                class="btn btn-sm btn-primary"
              >{gettext("Save folders")}</button>
              <button type="button" phx-click="folder-cancel" class="btn btn-sm btn-ghost">{gettext(
                "Cancel"
              )}</button>
            </form>
          </div>
        </.card>
        <.card
          :if={@can.wifi}
          title={gettext("Device Wi-Fi")}
          note={!@online && gettext("Available when the device is online")}
        >
          <.form for={@wifi_form} id="wifi-form" phx-submit="wifi" class="space-y-2">
            <.input
              field={@wifi_form[:ssid]}
              label={gettext("Network name (SSID)")}
              maxlength={Bastion.Control.ssid_max_length()}
              autocomplete="off"
              disabled={!@online}
              required
            />
            <.input
              field={@wifi_form[:password]}
              type="password"
              label={gettext("Password")}
              maxlength="63"
              autocomplete="new-password"
              disabled={!@online}
            />
            <p class="flex items-start gap-2 text-sm text-warning">
              <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
              {gettext(
                "With a wrong password the device loses its connection and can only be recovered with the button on site."
              )}
            </p>
            <button
              type="submit"
              class="btn btn-warning btn-sm"
              id="wifi-submit"
              disabled={!@online}
              data-confirm={
                gettext(
                  "Switch %{name} to the new network? The device reboots. If the name or password is wrong, it can only be recovered with the button on site.",
                  name: @device.name
                )
              }
            >
              {gettext("Switch network")}
            </button>
          </.form>
        </.card>
      </div>

      <div
        :if={@can.reboot or @can.revoke}
        class="rounded-box border border-error/40 bg-base-100 p-4 lg:col-span-2"
        id="danger-zone"
      >
        <h2 class="font-semibold text-error">{gettext("Danger zone")}</h2>
        <div class="mt-3 divide-y divide-base-300">
          <.danger_action
            :if={@can.reboot}
            title={gettext("Reboot")}
            description={
              if @online,
                do: gettext("The console and the connection are interrupted for a few seconds."),
                else: gettext("Available when the device is online.")
            }
          >
            <button
              type="button"
              class="btn btn-sm"
              id="reboot"
              disabled={!@online}
              phx-click="reboot"
              data-confirm={gettext("Reboot %{name}?", name: @device.name)}
            >
              {gettext("Reboot")}
            </button>
          </.danger_action>
          <.danger_action
            :if={@can.revoke}
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
            :if={@can.revoke}
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
        <div :if={@online && @online[:uart]} id="uart-diagnostics" class="space-y-2">
          <h3 class="font-semibold">{gettext("UART diagnostics")}</h3>
          <.info_row label={gettext("Received bytes")}>{@online[:uart]["rx_bytes"]}</.info_row>
          <.info_row label={gettext("Transmitted bytes")}>{@online[:uart]["tx_bytes"]}</.info_row>
          <.info_row label={gettext("Frame errors")}>{@online[:uart]["frame_errors"]}</.info_row>
          <.info_row label={gettext("Parity errors")}>{@online[:uart]["parity_errors"]}</.info_row>
          <.info_row label={gettext("Buffer overflows")}>{@online[:uart]["overflows"]}</.info_row>
          <.info_row label={gettext("RX pin level")}>{@online[:uart]["rx_level"]}</.info_row>
          <p class="text-xs text-base-content/60">
            {gettext(
              "Counters since device boot. TX counts bytes accepted by the UART driver. RX pin level alone does not prove connectivity."
            )}
          </p>
        </div>
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
  attr :filter, :string, required: true

  defp journal_tab(assigns) do
    filtered =
      Enum.filter(assigns.events, fn e ->
        case assigns.filter do
          "console" -> e.type in [:console_taken, :console_released]
          "commands" -> e.type == :command
          "connection" -> e.type in [:connected, :disconnected]
          _ -> true
        end
      end)

    assigns = assign(assigns, :filtered_events, filtered)

    ~H"""
    <section class="rounded-box border border-base-300 bg-base-100" id="journal">
      <div class="flex flex-wrap items-start justify-between gap-4 border-b border-base-300 p-4">
        <div>
          <h2 class="font-semibold">{gettext("Device activity")}</h2>
          <p class="mt-1 text-sm text-base-content/60">
            {gettext(
              "Latest 200 events. Control actions are recorded; terminal text is not stored in this journal."
            )}
          </p>
        </div>
        <form id="journal-filter" phx-change="journal-filter">
          <select name="type" class="select select-sm" aria-label={gettext("Event type")}>
            <option
              :for={
                {label, value} <- [
                  {gettext("All events"), "all"},
                  {gettext("Console sessions"), "console"},
                  {gettext("Control actions"), "commands"},
                  {gettext("Connection"), "connection"}
                ]
              }
              value={value}
              selected={@filter == value}
            >
              {label}
            </option>
          </select>
        </form>
      </div>
      <p :if={@filtered_events == []} class="px-4 py-6 text-sm text-base-content/50">
        {gettext("No events yet")}
      </p>
      <ol :if={@filtered_events != []} class="divide-y divide-base-300">
        <li
          :for={event <- @filtered_events}
          id={"event-#{event.id}"}
          class="flex items-start gap-3 px-4 py-3"
        >
          <span class="mt-0.5 grid size-7 shrink-0 place-items-center rounded-full bg-base-200">
            <.icon name={event_icon(event.type)} class="size-4" />
          </span>
          <div class="min-w-0 flex-1 text-sm">
            <p>{event_text(event)}</p>
            <p class="mt-1 text-xs text-base-content/55">{event.data["by"] || gettext("System")}</p>
          </div>
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

  defp workspace_path("/?" <> _ = path), do: path
  defp workspace_path(_), do: "/"

  defp tab_path(device, tab, return_path) do
    path = tab_path(device, tab)
    if return_path == "/", do: path, else: path <> "?" <> URI.encode_query(%{from: return_path})
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

  defp event_text(%{type: :moved, data: %{"folders" => []}}),
    do: gettext("Removed from all folders")

  defp event_text(%{type: :moved, data: %{"folders" => names}}),
    do: gettext("Folders: %{folders}", folders: Enum.join(names, ", "))

  defp event_text(%{type: :moved, data: %{"folder" => nil}}), do: gettext("Moved out of folders")

  defp event_text(%{type: :moved, data: d}),
    do: gettext("Moved to folder “%{folder}”", folder: d["folder"])

  defp event_text(%{type: :connected}), do: gettext("Connected")
  defp event_text(%{type: :disconnected}), do: gettext("Disconnected")
  defp event_text(%{type: :console_taken}), do: gettext("Console taken")
  defp event_text(%{type: :console_released}), do: gettext("Console released")

  defp event_text(%{type: :command, data: %{"op" => "command_sequence"} = d}),
    do:
      gettext("Configuration transfer: %{status}, %{sent}/%{total} lines · Run %{id}",
        status: sequence_status_text(d["status"]),
        sent: d["sent"],
        total: d["total"],
        id: d["run_id"]
      )

  defp event_text(%{type: :command, data: %{"op" => "console_config"} = d}),
    do: gettext("Port settings changed: %{line}", line: d["line"] || "—")

  defp event_text(%{type: :command, data: %{"op" => "console_break"}}), do: gettext("BREAK sent")
  defp event_text(%{type: :command, data: %{"op" => "reboot"}}), do: gettext("Reboot requested")

  defp event_text(%{type: :command, data: %{"op" => "wifi_config"} = d}),
    do: gettext("Wi-Fi changed to %{ssid}", ssid: d["ssid"] || "—")

  defp event_text(%{type: :command, data: d}), do: gettext("Control action: %{op}", op: d["op"])
  defp sequence_status_text("running"), do: gettext("started")
  defp sequence_status_text("completed"), do: gettext("all lines sent")
  defp sequence_status_text(_), do: gettext("stopped")
end
