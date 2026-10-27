defmodule BastionWeb.CAHTML do
  use BastionWeb, :html

  embed_templates "ca_html/*"

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  def os(assigns) do
    ~H"""
    <section id={@id} class="rounded-box border border-base-300 bg-base-100 p-4">
      <h2 class="mb-2 flex items-center gap-2 font-semibold">
        <.icon name={@icon} class="size-5" /> {@title}
      </h2>
      <div class="space-y-2 text-sm text-base-content/80">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :text, :string, required: true

  def cmd(assigns) do
    ~H"""
    <pre class="overflow-x-auto rounded-box bg-base-200 p-3 font-mono text-xs"><code>{@text}</code></pre>
    """
  end
end
