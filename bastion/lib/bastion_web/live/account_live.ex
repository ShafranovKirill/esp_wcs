defmodule BastionWeb.AccountLive do
  use BastionWeb, :live_view

  alias Bastion.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("Account"), form: empty_form())}
  end

  defp empty_form, do: to_form(%{"current" => "", "new" => "", "confirm" => ""}, as: :password)

  @impl true
  def handle_event("change-password", %{"password" => params}, socket) do
    %{"current" => current, "new" => new, "confirm" => confirm} = params

    result =
      if new == confirm,
        do: Accounts.change_password(socket.assigns.current_actor, current, new),
        else: {:error, :mismatch}

    case result do
      :ok ->
        {:noreply,
         socket |> assign(form: empty_form()) |> put_flash(:info, gettext("Password changed"))}

      {:error, reason} ->
        field = if reason == :invalid_current, do: :current, else: :new

        form =
          to_form(%{"current" => "", "new" => "", "confirm" => ""},
            as: :password,
            errors: [{field, {BastionWeb.Errors.message(reason), []}}]
          )

        {:noreply, assign(socket, form: form)}
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
      <div>
        <h1 class="text-2xl font-semibold">{gettext("Account")}</h1>
        <p class="text-sm text-base-content/60">{@current_user.username}</p>
      </div>

      <section class="card max-w-md border border-base-300 bg-base-100" id="password-section">
        <div class="card-body">
          <h2 class="card-title text-base">{gettext("Change password")}</h2>
          <.form for={@form} id="password-form" phx-submit="change-password">
            <.input
              field={@form[:current]}
              type="password"
              label={gettext("Current password")}
              autocomplete="current-password"
              required
            />
            <.input
              field={@form[:new]}
              type="password"
              label={gettext("New password")}
              autocomplete="new-password"
              minlength={Accounts.password_min_length()}
              required
            />
            <.input
              field={@form[:confirm]}
              type="password"
              label={gettext("Repeat the new password")}
              autocomplete="new-password"
              required
            />
            <p class="text-sm text-base-content/60">
              {gettext("At least %{min} characters.", min: Accounts.password_min_length())}
            </p>
            <button type="submit" class="btn btn-primary mt-2">{gettext("Change password")}</button>
          </.form>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
