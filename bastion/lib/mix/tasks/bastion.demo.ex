defmodule Mix.Tasks.Bastion.Demo do
  @shortdoc "Тестовые папки, устройства, сотрудники и права (только для разработки)"
  use Mix.Task

  use Boundary,
    top_level?: true,
    deps: [Bastion.Demo, Bastion.Repo, Bastion.PKI, Bastion.Accounts]

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_args) do
    if Mix.env() == :prod, do: Mix.raise("bastion.demo — только для разработки")

    Logger.configure(level: :warning)
    Application.load(:bastion)

    for app <- Application.spec(:bastion, :applications),
        do: {:ok, _} = Application.ensure_all_started(app)

    {:ok, _} =
      Supervisor.start_link(
        [Bastion.Repo, {Phoenix.PubSub, name: Bastion.PubSub}, Bastion.PKI, Bastion.Accounts],
        strategy: :one_for_one
      )

    case Bastion.Demo.seed() do
      {:ok, staff} ->
        Mix.shell().info("Созданы папки, устройства, группа «Сетевики А» и сотрудники:")
        for {name, password} <- staff, do: Mix.shell().info("  #{name} / #{password}")
        Bastion.Accounts.sync_journal()

      {:error, :already_seeded} ->
        Mix.raise(
          "Демо уже создано: есть папка «Здание А», «Здание Б», «Ядро сети» или сотрудник из демо"
        )
    end
  end
end
