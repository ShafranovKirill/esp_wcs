defmodule Bastion.Accounts.Infrastructure.SessionRecord do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_sessions" do
    field :token_hash, :binary, redact: true
    field :last_seen_at, :utc_datetime
    field :remote_ip, :string
    belongs_to :user, Bastion.Accounts.Infrastructure.UserRecord

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
