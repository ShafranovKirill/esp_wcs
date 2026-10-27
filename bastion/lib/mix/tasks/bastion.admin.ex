defmodule Mix.Tasks.Bastion.Admin do
  @shortdoc "Создаёт администратора из .env (--reset — перезаписать пароль)"
  use Mix.Task
  use Boundary, top_level?: true, deps: [Bastion.Release]

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [reset: :boolean])
    Logger.configure(level: :info)
    Bastion.Release.admin(reset: Keyword.get(opts, :reset, false))
  end
end
