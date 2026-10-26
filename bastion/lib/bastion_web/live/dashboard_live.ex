defmodule BastionWeb.DashboardLive do
  @moduledoc "Главная: устройства по папкам и заявки (наполняется в следующих шагах)"
  use BastionWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Devices"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin}>
      <h1 class="text-2xl font-semibold">{gettext("Devices")}</h1>
    </Layouts.app>
    """
  end
end
