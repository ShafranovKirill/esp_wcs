defmodule Bastion.Release do
  use Boundary, top_level?: true, deps: [Bastion.Accounts, Bastion.Repo]

  @app :bastion

  def migrate do
    load_app()

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  def admin(opts \\ []) do
    load_app()
    config = Application.get_env(@app, :admin, [])

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Bastion.Repo, fn _repo ->
        Bastion.Accounts.ensure_admin(config[:username], config[:password], opts)
      end)

    case result do
      {:ok, :created} ->
        IO.puts("Администратор «#{config[:username]}» создан")

      {:ok, :reset} ->
        IO.puts(
          "Пароль «#{config[:username]}» перезаписан, учётная запись разблокирована, её сессии завершены"
        )

      {:ok, :unchanged} ->
        IO.puts(
          "Сотрудники уже есть, ничего не изменено (перезаписать пароль «#{config[:username]}»: --reset)"
        )

      {:error, reason} ->
        fail(reason)
    end

    result
  end

  defp fail(:missing), do: halt("BASTION_ADMIN_PASSWORD не задан в .env")

  defp fail(:placeholder),
    do: halt("BASTION_ADMIN_PASSWORD — значение из шаблона, задайте свой пароль")

  defp fail(:too_short),
    do: halt("BASTION_ADMIN_PASSWORD короче #{Bastion.Accounts.password_min_length()} символов")

  defp fail(:invalid_username),
    do: halt("BASTION_ADMIN_USERNAME: 1–64 символа, буквы, цифры, . _ -")

  defp fail(reason), do: halt("не удалось записать администратора: #{inspect(reason)}")

  defp halt(message) do
    IO.puts(:stderr, "Ошибка: " <> message)
    System.halt(1)
  end

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
