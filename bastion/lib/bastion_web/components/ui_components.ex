defmodule BastionWeb.UIComponents do
  use Phoenix.Component
  use Gettext, backend: BastionWeb.Gettext

  alias Phoenix.LiveView.JS

  import BastionWeb.CoreComponents, only: [icon: 1]

  attr :status, :atom, required: true
  attr :class, :any, default: nil

  def status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm gap-1", status_class(@status), @class]}>
      <span class="size-1.5 rounded-full bg-current"></span>
      {status_text(@status)}
    </span>
    """
  end

  defp status_class(:pending), do: "badge-warning badge-soft"
  defp status_class(:approved), do: "badge-success badge-soft"
  defp status_class(:revoked), do: "badge-error badge-soft"

  def status_text(:pending), do: gettext("Awaiting approval")
  def status_text(:approved), do: gettext("Approved")
  def status_text(:revoked), do: gettext("Revoked")

  attr :device, :map, required: true
  attr :online, :map, default: nil

  def presence(assigns) do
    ~H"""
    <span :if={@online} class="inline-flex items-center gap-1.5 text-sm text-success">
      <span class="relative flex size-2">
        <span class="absolute inline-flex size-full animate-ping rounded-full bg-success opacity-60"></span>
        <span class="relative inline-flex size-2 rounded-full bg-success"></span>
      </span>
      {gettext("online")}
      <span :if={@online[:rtt]} class="text-base-content/60">· {gettext("%{ms} ms", ms: @online[:rtt])}</span>
      <.signal :if={@online[:rssi]} rssi={@online[:rssi]} />
    </span>
    <span :if={!@online} class="inline-flex items-center gap-1.5 text-sm text-base-content/60">
      <span class="size-2 rounded-full bg-base-content/25"></span>
      <%= if @device.last_seen_at do %>
        {gettext("offline")} ·
        <.time at={@device.last_seen_at} format="relative" id={"seen-#{@device.id}"} />
      <% else %>
        {gettext("never connected")}
      <% end %>
    </span>
    """
  end

  attr :rssi, :integer, required: true

  def signal(assigns) do
    assigns = assign(assigns, :bars, signal_bars(assigns.rssi))

    ~H"""
    <span
      class="inline-flex items-end gap-px"
      title={"#{@rssi} dBm"}
      aria-label={gettext("Signal %{bars} of 4", bars: @bars)}
    >
      <span
        :for={i <- 1..4}
        class={["w-1 rounded-sm", if(i <= @bars, do: "bg-current", else: "bg-base-content/20")]}
        style={"height: #{3 + i * 3}px"}
      ></span>
    </span>
    """
  end

  def signal_bars(rssi) when rssi >= -55, do: 4
  def signal_bars(rssi) when rssi >= -67, do: 3
  def signal_bars(rssi) when rssi >= -75, do: 2
  def signal_bars(_rssi), do: 1

  attr :code, :string, required: true
  attr :size, :string, default: "md", values: ~w(sm md lg)
  attr :rest, :global

  def code(assigns) do
    ~H"""
    <code
      class={[
        "rounded-md bg-base-200 font-mono font-semibold tracking-wider",
        @size == "sm" && "px-1.5 py-0.5 text-xs",
        @size == "md" && "px-2 py-1 text-sm",
        @size == "lg" && "px-3 py-1.5 text-xl"
      ]}
      {@rest}
    >
      {@code}
    </code>
    """
  end

  attr :at, DateTime, required: true
  attr :id, :string, required: true
  attr :format, :string, default: "datetime", values: ~w(datetime relative)

  def time(assigns) do
    ~H"""
    <time id={@id} phx-hook="LocalTime" datetime={DateTime.to_iso8601(@at)} data-format={@format}>
      {Calendar.strftime(@at, "%Y-%m-%d %H:%M UTC")}
    </time>
    """
  end

  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :class, :any, default: "btn btn-ghost btn-xs"

  def copy_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-hook="Clipboard"
      data-copy={@text}
      data-copied-text={gettext("Copied")}
      class={@class}
      aria-label={gettext("Copy")}
    >
      <.icon name="hero-clipboard-document" class="size-4" />
      <span data-copy-label>{gettext("Copy")}</span>
    </button>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true
  slot :actions

  def dialog(assigns) do
    ~H"""
    <dialog id={@id} class="modal" phx-mounted={JS.ignore_attributes(["open"])}>
      <div class="modal-box">
        <h3 class="text-lg font-semibold">{@title}</h3>
        <div class="py-4 space-y-3">{render_slot(@inner_block)}</div>
        <div :if={@actions != []} class="modal-action">
          {render_slot(@actions)}
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button aria-label={gettext("Close")}>{gettext("Close")}</button>
      </form>
    </dialog>
    """
  end

  def open_dialog(js \\ %JS{}, id), do: JS.dispatch(js, "bastion:open-dialog", to: "##{id}")
  def close_dialog(js \\ %JS{}, id), do: JS.dispatch(js, "bastion:close-dialog", to: "##{id}")
end
