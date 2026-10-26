defmodule Bastion.Repo do
  @moduledoc """
  Репозиторий Ecto. Используется только инфраструктурным слоем контекстов;
  веб-интерфейс к нему не обращается (проверяет `boundary`).
  """
  use Boundary, top_level?: true, deps: []

  use Ecto.Repo,
    otp_app: :bastion,
    adapter: Ecto.Adapters.Postgres
end
