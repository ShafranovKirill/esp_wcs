defmodule BastionWeb.FolderMapLive do
  use BastionWeb, :live_view
  alias Bastion.{Maps, Fleet, Link, Console}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Fleet.subscribe()
      Link.subscribe()
    end

    {:ok,
     socket
     |> assign(
       page_title: gettext("Folder map"),
       editing: false,
       map_query: "",
       undo: [],
       cover_open: false,
       panel: false,
       show_unfiled: false,
       map: nil,
       subscribed: MapSet.new(),
       upload_form: to_form(%{}),
       upload_error: nil
     )
     |> allow_upload(:background,
       accept: ~w(.png .jpg .jpeg .webp),
       max_entries: 1,
       auto_upload: true,
       chunk_timeout: 30_000,
       max_file_size: 20 * 1024 * 1024
     )}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    if connected?(socket), do: Maps.subscribe(id)

    {:noreply,
     socket
     |> cancel_background_uploads()
     |> assign(
       cover_open: false,
       folder_id: id,
       return_path: workspace_path(params["from"]),
       undo: [],
       editing: false,
       panel: false,
       show_unfiled: false,
       upload_error: nil
     )
     |> load()}
  end

  defp load(socket) do
    case Maps.fetch(socket.assigns.current_actor, socket.assigns.folder_id) do
      {:ok, map} ->
        devices =
          Fleet.overview(socket.assigns.current_actor).devices
          |> Map.values()
          |> List.flatten()
          |> Enum.uniq_by(& &1.id)

        ids = MapSet.new(devices, & &1.id)

        if connected?(socket) do
          Enum.each(MapSet.difference(ids, socket.assigns.subscribed), &Console.subscribe/1)
        end

        online = Link.online()

        statuses =
          Map.new(devices, fn d ->
            status =
              cond do
                not Map.has_key?(online, d.id) -> "offline"
                Console.lock(d.id) != :free -> "busy"
                true -> "online"
              end

            {d.id, status}
          end)

        folders = Map.new(Fleet.list_folders(), &{&1.id, &1})

        items =
          Enum.map(map.items, fn item ->
            status =
              if item.kind == "device" do
                Map.get(statuses, item.id, "offline")
              else
                contained =
                  Enum.filter(devices, fn d ->
                    Enum.any?(d.folder_ids, fn id ->
                      f = folders[id]
                      f && item.id in f.path
                    end)
                  end)

                states = Enum.map(contained, &statuses[&1.id])

                cond do
                  states == [] -> "empty"
                  "offline" in states -> "offline"
                  "busy" in states -> "busy"
                  true -> "online"
                end
              end

            item
            |> Map.put(:status, status)
            |> Map.put(
              :url,
              if(item.kind == "folder",
                do: ~p"/folders/#{item.id}/map?#{%{from: socket.assigns.return_path}}",
                else: ~p"/devices/#{item.id}?#{%{from: socket.assigns.return_path}}"
              )
            )
          end)

        socket
        |> assign(
          map: %{map | items: items},
          subscribed: MapSet.union(ids, socket.assigns.subscribed),
          editing: socket.assigns.editing and map.editable
        )

      _ ->
        socket |> put_flash(:error, gettext("Map unavailable")) |> push_navigate(to: ~p"/")
    end
  end

  @impl true
  def handle_info({:event, _}, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("map-search", %{"q" => query}, socket),
    do: {:noreply, assign(socket, map_query: String.slice(query, 0, 120))}

  def handle_event("map-focus", %{"id" => id}, socket),
    do: {:noreply, socket |> assign(map_query: "") |> push_event("map-focus", %{id: id})}

  def handle_event("toggle-edit", _, socket) do
    socket = socket |> cancel_background_uploads() |> load()

    {:noreply,
     assign(socket,
       editing: socket.assigns.map.editable and not socket.assigns.editing,
       panel: true
     )}
  end

  def handle_event("close-map", _, socket),
    do: {:noreply, push_navigate(socket, to: socket.assigns.return_path)}

  def handle_event("change-cover", _, socket),
    do: {:noreply, assign(socket, panel: true, cover_open: not socket.assigns.cover_open)}

  def handle_event("toggle-panel", _, socket),
    do: {:noreply, assign(socket, panel: not socket.assigns.panel)}

  def handle_event("show-unfiled", _, socket) do
    {:noreply,
     assign(socket,
       panel: true,
       show_unfiled: not socket.assigns.show_unfiled,
       editing: socket.assigns.map.editable
     )}
  end

  def handle_event("place", %{"kind" => kind, "id" => id, "x" => x, "y" => y}, socket) do
    update_position(socket, kind, id, {x, y}, fn ->
      Maps.place(socket.assigns.current_actor, socket.assigns.folder_id, kind, id, x, y)
    end)
  end

  def handle_event("remove", %{"kind" => kind, "id" => id}, socket) do
    update_position(socket, kind, id, nil, fn ->
      Maps.remove(socket.assigns.current_actor, socket.assigns.folder_id, kind, id)
    end)
  end

  def handle_event("undo", _, %{assigns: %{undo: [last | rest]}} = socket) do
    {kind, id, expected, previous} = last

    case Maps.restore_position(
           socket.assigns.current_actor,
           socket.assigns.folder_id,
           kind,
           id,
           expected,
           previous
         ) do
      :ok ->
        {:noreply, socket |> assign(undo: rest) |> load()}

      _ ->
        {:noreply,
         socket
         |> assign(undo: [])
         |> load()
         |> put_flash(
           :error,
           gettext("Cannot undo: the item changed. Reload the map and try again.")
         )}
    end
  end

  def handle_event("undo", _, socket), do: {:noreply, socket}

  def handle_event("clear-background", _, socket),
    do:
      mutate(socket, fn ->
        Maps.clear_background(socket.assigns.current_actor, socket.assigns.folder_id)
      end)

  def handle_event("validate-upload", _, socket),
    do: {:noreply, assign(socket, upload_error: nil)}

  def handle_event("cancel-upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :background, ref)}

  def handle_event("upload", _, socket) do
    cond do
      not socket.assigns.map.editable ->
        {:noreply, assign(socket, upload_error: gettext("You do not have the right to do this"))}

      not upload_ready?(socket.assigns.uploads.background) ->
        {:noreply,
         assign(socket,
           upload_error: gettext("Choose an image and wait for the upload to finish")
         )}

      true ->
        results =
          consume_uploaded_entries(socket, :background, fn %{path: path}, _entry ->
            case Maps.set_background(socket.assigns.current_actor, socket.assigns.folder_id, path) do
              {:ok, _} = result -> {:ok, result}
              {:error, :invalid_image} = result -> {:ok, result}
              error -> {:postpone, error}
            end
          end)

        case Enum.find(results, &match?({:error, _}, &1)) do
          nil ->
            {:noreply,
             socket
             |> assign(upload_error: nil)
             |> load()
             |> put_flash(:info, gettext("Background updated"))}

          {:error, reason} ->
            {:noreply, assign(socket, upload_error: background_error(reason))}
        end
    end
  end

  defp cancel_background_uploads(socket) do
    Enum.reduce(socket.assigns.uploads.background.entries, socket, fn entry, socket ->
      cancel_upload(socket, :background, entry.ref)
    end)
  end

  defp upload_ready?(upload) do
    upload.entries != [] and upload_errors(upload) == [] and
      Enum.all?(upload.entries, &(&1.done? and upload_errors(upload, &1) == []))
  end

  defp background_error(:invalid_image),
    do: gettext("Use PNG, JPEG or WebP, up to 20 MB and 8000 × 8000 pixels")

  defp background_error(:storage_denied),
    do: gettext("Storage access denied. Check the S3 credentials.")

  defp background_error(:storage_not_configured), do: gettext("Image storage is not configured")
  defp background_error(_), do: gettext("Image storage is unavailable. Try saving again.")

  defp upload_error_text(:too_large), do: gettext("The image must be smaller than 20 MB")
  defp upload_error_text(:not_accepted), do: gettext("Choose a PNG, JPEG or WebP image")
  defp upload_error_text(:too_many_files), do: gettext("Choose one image")
  defp upload_error_text(_), do: gettext("Upload interrupted. Remove the file and try again.")

  defp update_position(socket, kind, id, next, fun) do
    item = Enum.find(socket.assigns.map.items, &(&1.id == id and &1.kind == kind))
    previous = if item && item.x != nil, do: {item.x, item.y}, else: nil

    case fun.() do
      result when result == :ok or (is_tuple(result) and elem(result, 0) == :ok) ->
        undo =
          if kind in ["device", "folder"] and previous != next,
            do: Enum.take([{kind, id, next, previous} | socket.assigns.undo], 20),
            else: socket.assigns.undo

        {:noreply, socket |> assign(undo: undo) |> load()}

      _ ->
        {:noreply, socket |> put_flash(:error, gettext("Could not update the map")) |> load()}
    end
  end

  defp mutate(socket, fun) do
    case fun.() do
      :ok -> {:noreply, load(socket)}
      {:ok, _} -> {:noreply, load(socket)}
      _ -> {:noreply, socket |> put_flash(:error, gettext("Could not update the map")) |> load()}
    end
  end

  defp workspace_path("/?" <> _ = path), do: path
  defp workspace_path(_), do: "/?view=folders"

  defp map_matches(items, query) do
    q = String.downcase(String.trim(query))
    items |> Enum.filter(&String.contains?(String.downcase(&1.name), q)) |> Enum.take(10)
  end

  defp canvas_data(map) do
    Jason.encode!(Enum.filter(map.items, &(not is_nil(&1.x))))
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
      wide={true}
      map_mode={true}
    >
      <div
        :if={@map}
        id="folder-map-page"
        class="flex h-dvh flex-col overflow-hidden bg-base-100"
      >
        <div
          id="map-command-bar"
          class="z-30 flex min-h-16 shrink-0 flex-wrap items-center justify-between gap-2 border-b border-base-300 bg-base-100 px-4 py-2 shadow-sm"
        >
          <div class="flex min-w-0 items-center gap-3">
            <.link
              id="map-back"
              navigate={
                if @map.folder.parent_id, do: ~p"/folders/#{@map.folder.parent_id}/map", else: ~p"/"
              }
              class="flex size-9 shrink-0 items-center justify-center rounded-lg border border-base-300 hover:bg-base-200"
              aria-label={gettext("Back")}
            ><.icon name="hero-arrow-left" class="size-5" /></.link>
            <nav id="map-breadcrumbs" class="flex min-w-0 flex-wrap items-center gap-2 text-sm">
              <span :for={folder <- @map.breadcrumbs} class="contents">
                <span :if={folder.id != hd(@map.breadcrumbs).id} class="opacity-30">/</span>
                <.link
                  navigate={~p"/folders/#{folder.id}/map?#{%{from: @return_path}}"}
                  class={[
                    "truncate max-w-48 hover:text-primary",
                    folder.id == @folder_id && "font-semibold"
                  ]}
                >{folder.name}</.link>
              </span>
            </nav>
          </div>
          <form
            id="map-search-form"
            phx-change="map-search"
            phx-submit="map-search"
            class="relative min-w-48 flex-1 max-w-sm"
          >
            <input
              id="map-search"
              type="search"
              name="q"
              value={@map_query}
              phx-debounce="200"
              placeholder={gettext("Find on this map")}
              aria-label={gettext("Find on this map")}
              class="input input-sm w-full"
              autocomplete="off"
            />
            <div
              :if={@map_query != ""}
              id="map-search-results"
              class="absolute top-full mt-2 max-h-64 w-full overflow-auto rounded-xl border border-base-300 bg-base-100 p-2 shadow-xl"
            >
              <p
                :if={map_matches(@map.items, @map_query) == []}
                class="p-3 text-sm text-base-content/60"
              >
                {gettext("Nothing found")}
              </p>
              <div
                :for={item <- map_matches(@map.items, @map_query)}
                class="flex items-center gap-2 p-2 text-sm"
              >
                <button
                  :if={item.x != nil}
                  type="button"
                  phx-click="map-focus"
                  phx-value-id={item.id}
                  class="flex-1 truncate text-left hover:text-primary"
                >{item.name}</button>
                <span :if={item.x == nil} class="flex-1 truncate">{item.name}</span>
                <.link navigate={item.url} class="text-primary" aria-label={gettext("Open")}><.icon
                  name="hero-arrow-top-right-on-square"
                  class="size-4"
                /></.link>
              </div>
            </div>
          </form>
          <div class="flex items-center gap-2">
            <button
              :if={@editing and @undo != []}
              type="button"
              id="map-undo"
              phx-click="undo"
              class="btn btn-sm btn-ghost"
            ><.icon name="hero-arrow-uturn-left" class="size-4" />{gettext("Undo")}</button>
            <span
              :if={@editing}
              id="map-autosave"
              class="hidden sm:inline text-xs text-base-content/60"
            >{gettext("Changes save automatically")}</span>
            <button
              :if={@map.editable}
              id="map-edit"
              phx-click="toggle-edit"
              class={[
                "flex items-center gap-2 rounded-lg px-4 py-2 text-sm font-medium",
                if(@editing,
                  do: "bg-primary text-primary-content",
                  else: "border border-base-300 hover:bg-base-200"
                )
              ]}
            ><.icon name={if @editing, do: "hero-check", else: "hero-pencil-square"} class="size-4" />{if @editing,
              do: gettext("Done"),
              else: gettext("Edit map")}</button>
            <button
              id="map-close"
              phx-click="close-map"
              class="flex items-center gap-2 rounded-lg border border-base-300 px-3 py-2 text-sm hover:bg-base-200"
            ><.icon name="hero-x-mark" class="size-4" />{gettext("Close")}</button>
          </div>
        </div>
        <div class="relative min-h-0 flex-1" id="map-workspace">
          <div class="absolute right-3 top-16 z-20 flex max-w-[calc(100%-1.5rem)] flex-wrap justify-end gap-2">
            <button
              :if={@map.editable}
              id="map-unfiled-toggle"
              phx-click="show-unfiled"
              class="rounded-xl border border-base-300 bg-base-100/95 px-4 py-2 text-sm shadow-lg backdrop-blur"
            >{gettext("Unassigned devices")} ({length(@map.unfiled)})</button>
            <button
              id="map-panel-toggle"
              phx-click="toggle-panel"
              class="rounded-xl border border-base-300 bg-base-100/95 px-4 py-2 text-sm shadow-lg backdrop-blur"
            >{gettext("Map layers")}</button>
          </div>
          <section class="flex h-full min-w-0 flex-col overflow-hidden bg-base-200">
            <div class="flex flex-wrap items-center gap-2 border-b border-base-300 bg-base-100 px-4 py-3">
              <button
                type="button"
                data-map-control="fullscreen"
                class="rounded border border-base-300 px-3 py-1"
                aria-label={gettext("Full screen")}
              ><.icon name="hero-arrows-pointing-out" class="size-4" /></button>
              <button type="button" data-map-control="fit" class="rounded border px-3 py-1">{gettext(
                "Fit to screen"
              )}</button>
              <button
                type="button"
                data-map-control="in"
                aria-label={gettext("Zoom in")}
                class="rounded border px-3 py-1"
              >+</button>
              <button
                type="button"
                data-map-control="out"
                aria-label={gettext("Zoom out")}
                class="rounded border px-3 py-1"
              >−</button>
              <span class="self-center text-xs opacity-60">{if @editing,
                do: gettext("Drag items onto the map or choose an item and click the map"),
                else: gettext("Click a folder to open its map")}</span>
            </div>
            <div
              id="folder-map"
              phx-hook="FolderMap"
              phx-update="ignore"
              class="relative min-h-0 flex-1 overflow-hidden touch-none map-canvas"
              data-items={canvas_data(@map)}
              data-editing={to_string(@editing)}
              data-background={
                if @map.background,
                  do:
                    ~p"/folders/#{@folder_id}/background?v=#{Path.basename(@map.background.background)}",
                  else: ""
              }
              data-width={if @map.background, do: @map.background.width, else: 1200}
              data-height={if @map.background, do: @map.background.height, else: 800}
              data-online={gettext("Online")}
              data-offline={gettext("Offline")}
              data-busy={gettext("Console busy")}
              data-empty={gettext("Empty folder")}
            >
            </div>
          </section>
          <aside
            id="map-inspector"
            class={[
              "absolute right-3 top-28 z-20 max-h-[calc(100%-8rem)] w-80 max-w-[calc(100%-2rem)] space-y-3 overflow-y-auto rounded-xl bg-base-100/95 p-3 shadow-2xl backdrop-blur",
              !@panel && "hidden"
            ]}
          >
            <section :if={@show_unfiled} class="space-y-3 rounded-xl border border-base-300 p-4">
              <h2 class="font-semibold">{gettext("Unassigned devices")}</h2>
              <p class="text-xs opacity-60">
                {gettext("Drop a device on the map to add it to this folder")}
              </p>
              <button
                :for={device <- @map.unfiled}
                id={"unfiled-#{device.id}"}
                type="button"
                draggable="true"
                data-map-kind="unfiled"
                data-map-id={device.id}
                class="flex w-full items-center gap-2 rounded-lg border border-base-300 p-3 text-left text-sm hover:border-primary"
              >
                <.icon name="hero-cpu-chip" class="size-5" />{device.name}
              </button>
            </section>
            <section class="rounded-xl border border-base-300 p-4">
              <h2 class="font-semibold">{gettext("Unplaced items")}</h2>
              <p :if={Enum.all?(@map.items, &(not is_nil(&1.x)))} class="mt-3 text-sm opacity-60">
                {gettext("All items are placed")}
              </p>
              <div id="map-unplaced" class="mt-3 space-y-2">
                <button
                  :for={item <- Enum.filter(@map.items, &is_nil(&1.x))}
                  id={"unplaced-#{item.id}"}
                  type="button"
                  draggable={to_string(@editing)}
                  data-map-kind={item.kind}
                  data-map-id={item.id}
                  disabled={!@editing}
                  class="flex w-full items-center gap-2 rounded-lg border border-base-300 p-3 text-left text-sm disabled:opacity-60"
                >
                  <.icon
                    name={if item.kind == "folder", do: "hero-folder", else: "hero-cpu-chip"}
                    class="size-5 shrink-0"
                  />{item.name}
                </button>
              </div>
            </section>
            <button
              :if={@editing}
              id="map-change-cover"
              phx-click="change-cover"
              class="flex w-full items-center gap-2 rounded-xl border border-base-300 bg-base-100 px-4 py-3 text-sm font-medium hover:bg-base-200"
            ><.icon name="hero-photo" class="size-5" />{gettext("Change cover")}</button>
            <section
              :if={@editing and @cover_open}
              id="map-background-panel"
              class="overflow-hidden rounded-xl border border-base-300 bg-base-100"
            >
              <div class="border-b border-base-300 px-4 py-3">
                <h2 class="flex items-center gap-2 font-semibold">
                  <.icon name="hero-photo" class="size-4 opacity-60" />{gettext("Background photo")}
                </h2>
                <p class="mt-1 text-xs text-base-content/50">
                  {gettext("PNG, JPEG or WebP · up to 20 MB · 8000 × 8000 pixels")}
                </p>
              </div>
              <.form
                for={@upload_form}
                id="map-upload"
                phx-change="validate-upload"
                phx-submit="upload"
                class="space-y-3 p-4"
              >
                <.live_file_input
                  upload={@uploads.background}
                  class="sr-only"
                  aria-label={gettext("Choose a photo")}
                />
                <label
                  :if={@uploads.background.entries == []}
                  id="map-upload-dropzone"
                  for={@uploads.background.ref}
                  phx-drop-target={@uploads.background.ref}
                  class="group relative flex min-h-36 cursor-pointer flex-col items-center justify-center gap-2 rounded-lg border-2 border-dashed border-base-300 bg-base-200/30 p-4 text-center transition hover:border-primary/60 hover:bg-primary/5 focus-within:ring-2 focus-within:ring-primary"
                >
                  <.icon
                    name="hero-arrow-up-tray"
                    class="size-7 text-base-content/40 transition group-hover:text-primary"
                  />
                  <span class="text-sm font-medium">{gettext("Choose a photo")}</span>
                  <span class="text-xs text-base-content/50">{gettext("or drag it here")}</span>
                </label>
                <div
                  :for={entry <- @uploads.background.entries}
                  id={"map-upload-entry-#{entry.ref}"}
                  class="overflow-hidden rounded-lg border border-base-300"
                >
                  <div class="relative aspect-video overflow-hidden bg-base-200">
                    <.live_img_preview
                      :if={upload_errors(@uploads.background, entry) == []}
                      entry={entry}
                      class="h-full w-full object-contain"
                    />
                    <div
                      :if={upload_errors(@uploads.background, entry) != []}
                      class="flex h-full items-center justify-center text-error"
                    >
                      <.icon name="hero-exclamation-triangle" class="size-8" />
                    </div>
                    <button
                      type="button"
                      phx-click="cancel-upload"
                      phx-value-ref={entry.ref}
                      aria-label={gettext("Remove selected photo")}
                      class="absolute right-2 top-2 flex size-7 items-center justify-center rounded-full bg-base-100/95 text-base-content shadow hover:bg-base-300"
                    >
                      <.icon name="hero-x-mark" class="size-4" />
                    </button>
                  </div>
                  <div class="space-y-2 p-3">
                    <p class="truncate text-xs font-medium" title={entry.client_name}>
                      {entry.client_name}
                    </p>
                    <div class="flex items-center justify-between text-xs text-base-content/50">
                      <span>{if entry.done?,
                        do: gettext("Ready to save"),
                        else: gettext("Uploading photo")}</span><span>{entry.progress}%</span>
                    </div>
                    <progress
                      class="h-1.5 w-full overflow-hidden rounded-full accent-primary"
                      value={entry.progress}
                      max="100"
                    >{entry.progress}%</progress>
                    <p
                      :for={error <- upload_errors(@uploads.background, entry)}
                      role="alert"
                      class="text-xs text-error"
                    >
                      {upload_error_text(error)}
                    </p>
                  </div>
                </div>
                <p
                  :for={error <- upload_errors(@uploads.background)}
                  role="alert"
                  class="text-xs text-error"
                >
                  {upload_error_text(error)}
                </p>
                <p
                  :if={@upload_error}
                  id="map-upload-error"
                  role="alert"
                  class="rounded-lg border border-error/20 bg-error/5 p-3 text-xs text-error"
                >
                  {@upload_error}
                </p>
                <button
                  id="map-upload-save"
                  type="submit"
                  phx-disable-with={gettext("Saving background…")}
                  disabled={!upload_ready?(@uploads.background)}
                  class="flex w-full items-center justify-center gap-2 rounded-lg bg-primary px-3 py-2.5 text-sm font-medium text-primary-content transition hover:brightness-110 disabled:cursor-not-allowed disabled:opacity-40"
                >
                  <.icon name="hero-check" class="size-4" />{gettext("Use as background")}
                </button>
                <p class="text-xs leading-relaxed text-base-content/45">
                  {gettext("Replacing the photo keeps all item positions")}
                </p>
              </.form>
              <div :if={@map.background} class="border-t border-base-300 px-4 py-3">
                <button
                  id="map-clear-background"
                  type="button"
                  phx-click="clear-background"
                  data-confirm={gettext("Remove the background? Item positions will be kept.")}
                  class="flex items-center gap-2 text-xs text-base-content/60 transition hover:text-error"
                ><.icon name="hero-trash" class="size-4" />{gettext("Remove background")}</button>
              </div>
            </section>
            <section :if={@editing} class="space-y-2 rounded-xl border border-base-300 p-4">
              <h2 class="font-semibold">{gettext("Placed items")}</h2>
              <div
                :for={item <- Enum.reject(@map.items, &is_nil(&1.x))}
                class="flex items-center justify-between gap-2 text-sm"
              >
                <span>{item.name}</span><button
                  id={"remove-placement-#{item.id}"}
                  phx-click="remove"
                  phx-value-kind={item.kind}
                  phx-value-id={item.id}
                  class="text-error"
                >{gettext("Remove")}</button>
              </div>
            </section>
          </aside>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
