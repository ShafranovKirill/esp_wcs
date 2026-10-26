defmodule Bastion.Accounts.Infrastructure.AdminSession do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "admin_sessions" do
    field :token_hash, :binary, redact: true
    field :last_seen_at, :utc_datetime
    field :remote_ip, :string
    belongs_to :admin, Bastion.Accounts.Infrastructure.Admin

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
