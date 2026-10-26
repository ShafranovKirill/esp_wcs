defmodule BastionWeb.LocaleController do
  use BastionWeb, :controller

  defdelegate update(conn, params), to: BastionWeb.Locale, as: :switch
end
