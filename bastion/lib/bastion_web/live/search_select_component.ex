defmodule BastionWeb.SearchSelectComponent do
  use BastionWeb, :live_component

  @impl true
  def update(assigns, socket) do
    previous = socket.assigns[:external_value]
    current = to_string(assigns.value || "")
    selected = if previous == current, do: socket.assigns[:selected] || current, else: current

    {:ok,
     socket
     |> assign(assigns)
     |> assign(external_value: current, selected: selected)
     |> assign_new(:query, fn -> "" end)
     |> assign_new(:open, fn -> false end)}
  end

  @impl true
  def handle_event("search", params, socket) do
    query = get_in(params, ["_picker_query", socket.assigns.id]) || ""
    {:noreply, assign(socket, query: String.slice(query, 0, 120), open: true)}
  end

  def handle_event("choose", %{"value" => value}, socket) do
    if Enum.any?(socket.assigns.options, fn {_, id} -> to_string(id) == value end),
      do: {:noreply, assign(socket, selected: value, query: "", open: false)},
      else: {:noreply, socket}
  end

  def handle_event("toggle", _, socket),
    do: {:noreply, assign(socket, open: not socket.assigns.open)}

  @impl true
  def render(assigns) do
    q = String.downcase(String.trim(assigns.query))

    results =
      Enum.filter(assigns.options, fn {label, _} ->
        String.contains?(String.downcase(label), q)
      end)

    selected_label =
      Enum.find_value(assigns.options, assigns.prompt, fn {label, id} ->
        if to_string(id) == assigns.selected, do: label
      end)

    assigns =
      assign(assigns,
        results: Enum.take(results, 20),
        result_count: length(results),
        selected_label: selected_label
      )

    ~H"""
    <div id={@id} class="space-y-2">
      <span class="block text-sm font-medium">{@label}</span>
      <input type="hidden" name={@name} value={@selected} />
      <button
        type="button"
        phx-click="toggle"
        phx-target={@myself}
        class="folder-result bg-base-100"
        aria-expanded={to_string(@open)}
      >
        <span class="min-w-0 flex-1 truncate">{@selected_label}</span>
        <.icon name="hero-chevron-down" class="size-4 shrink-0" />
      </button>
      <div :if={@open} class="space-y-2 rounded-lg border border-base-300 bg-base-100 p-2">
        <input
          type="search"
          id={"#{@id}-query"}
          name={"_picker_query[#{@id}]"}
          value={@query}
          phx-change="search"
          phx-target={@myself}
          phx-debounce="200"
          placeholder={gettext("Search")}
          aria-label={@label}
          class="input input-sm w-full"
          autocomplete="off"
        />
        <div class="max-h-52 space-y-1 overflow-y-auto" aria-live="polite">
          <button
            :for={{label, value} <- @results}
            type="button"
            phx-click="choose"
            phx-value-value={value}
            phx-target={@myself}
            class="folder-result"
            aria-pressed={to_string(to_string(value) == @selected)}
          >{label}</button>
          <p :if={@result_count == 0} class="p-2 text-xs text-base-content/60">
            {gettext("Nothing found")}
          </p>
          <p :if={@result_count > 20} class="p-2 text-xs text-base-content/60">
            {gettext("Showing the first 20 matches. Refine your search.")}
          </p>
        </div>
      </div>
    </div>
    """
  end
end
