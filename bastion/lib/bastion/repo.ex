defmodule Bastion.Repo do
  use Boundary, top_level?: true, deps: []

  use Ecto.Repo,
    otp_app: :bastion,
    adapter: Ecto.Adapters.Postgres
end
