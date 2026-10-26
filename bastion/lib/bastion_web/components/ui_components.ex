defmodule BastionWeb.UIComponents do
  @moduledoc "Общие элементы интерфейса бастиона: статусы, коды, время, копирование, диалоги"
  use Phoenix.Component
  use Gettext, backend: BastionWeb.Gettext

  alias Phoenix.LiveView.JS

  import BastionWeb.CoreComponents, only: [icon: 1]

  @doc "Статус устройства: заявка, одобрено, отозвано"
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

  @doc false
  def status_text(:pending), do: gettext("Awaiting approval")
  def status_text(:approved), do: gettext("Approved")
  def status_text(:revoked), do: gettext("Revoked")

  @doc """
  Связь с устройством. Онлайн-статус появится вместе с WCS Link; пока —
  когда устройство было на связи в последний раз.
  """
  attr :device, :map, required: true

  def presence(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 text-sm text-base-content/60">
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

  @doc "Код для сверки: моноширинный, крупный, группами"
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

  @doc "Время в часовом поясе браузера (`LocalTime`)"
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

  @doc "Кнопка «Копировать»"
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

  @doc """
  Модальное окно на `<dialog>`. Открыть: `phx-click={open_dialog("id")}`;
  закрыть с сервера: `push_event(socket, "close-dialog", %{id: "id"})`.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true
  slot :actions

  def dialog(assigns) do
    ~H"""
    <%!-- open ставит браузер (showModal) — LiveView не должен снимать его при перерисовке --%>
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
