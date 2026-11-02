defmodule Mix.Tasks.Bastion.Storage do
  @shortdoc "Создать или проверить закрытый S3-бакет карт"
  use Mix.Task
  use Boundary, top_level?: true, deps: [Bastion.Maps, Bastion.Repo, Bastion.Access]
  @requirements ["app.config"]

  def run(args) do
    for app <- [:req], do: {:ok, _} = Application.ensure_all_started(app)

    case Bastion.Maps.setup_storage() do
      :ok ->
        Mix.shell().info("S3-бакет карт готов")

        if "--migrate" in args do
          {:ok, _} = Application.ensure_all_started(:ecto_sql)
          {:ok, _} = Application.ensure_all_started(:postgrex)
          {:ok, _} = Bastion.Repo.start_link()
          {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

          {:ok, _} =
            Supervisor.start_link([{Phoenix.PubSub, name: Bastion.PubSub}],
              strategy: :one_for_one
            )

          results = Bastion.Maps.migrate_local_backgrounds(Bastion.Access.system())
          errors = Enum.filter(results, fn {_, result} -> not match?({:ok, _}, result) end)
          if errors != [], do: Mix.raise("Не удалось перенести #{length(errors)} фонов")
          Mix.shell().info("Перенесено фонов в S3: #{length(results)}")
        end

      {:error, reason} ->
        Mix.raise("S3 недоступно: #{reason}")
    end
  end
end
