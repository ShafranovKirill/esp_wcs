defmodule Mix.Tasks.Bastion.Admin do
  @shortdoc "Создаёт администратора из .env (--reset — перезаписать пароль)"
  @moduledoc """
  Создаёт учётную запись администратора из `BASTION_ADMIN_USERNAME` и
  `BASTION_ADMIN_PASSWORD` (`bastion/.env`). В БД попадает только хэш Argon2.

      mix bastion.admin           # создать, если нет; существующего не меняет
      mix bastion.admin --reset   # перезаписать пароль, завершить все сессии

  В релизе: `bin/bastion eval "Bastion.Release.admin()"`.
  """
  use Mix.Task
  use Boundary, top_level?: true, deps: [Bastion.Release]

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [reset: :boolean])
    # SQL-запросы в выводе задачи не нужны
    Logger.configure(level: :info)
    Bastion.Release.admin(reset: Keyword.get(opts, :reset, false))
  end
end
