defmodule BastionWeb.Locale do
  use BastionWeb, :verified_routes

  import Plug.Conn

  @locales ~w(ru en)
  @default "ru"
  @session_key "locale"

  @spec locales() :: [String.t()]
  def locales, do: @locales

  def init(opts), do: opts

  def call(conn, _opts) do
    locale = get_session(conn, @session_key) || from_header(conn) || @default
    Gettext.put_locale(BastionWeb.Gettext, locale)

    conn
    |> put_session(@session_key, locale)
    |> assign(:locale, locale)
  end

  def on_mount(:default, _params, session, socket) do
    locale = if session[@session_key] in @locales, do: session[@session_key], else: @default
    Gettext.put_locale(BastionWeb.Gettext, locale)

    socket =
      socket
      |> Phoenix.Component.assign(locale: locale, current_path: "/")
      |> Phoenix.LiveView.attach_hook(:current_path, :handle_params, fn _params, uri, socket ->
        {:cont, Phoenix.Component.assign(socket, :current_path, URI.parse(uri).path)}
      end)

    {:cont, socket}
  end

  def switch(conn, %{"locale" => locale} = params) when locale in @locales do
    conn
    |> put_session(@session_key, locale)
    |> Phoenix.Controller.redirect(to: safe_return_path(params["return_to"]))
  end

  def switch(conn, params),
    do: Phoenix.Controller.redirect(conn, to: safe_return_path(params["return_to"]))

  defp safe_return_path("/" <> rest = path) do
    if String.starts_with?(rest, ["/", "\\"]), do: ~p"/", else: path
  end

  defp safe_return_path(_), do: ~p"/"

  defp from_header(conn) do
    conn
    |> get_req_header("accept-language")
    |> List.first("")
    |> String.split(",")
    |> Enum.map(
      &(&1
        |> String.split(";")
        |> hd()
        |> String.trim()
        |> String.slice(0, 2)
        |> String.downcase())
    )
    |> Enum.find(&(&1 in @locales))
  end
end
