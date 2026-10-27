import Config

config :bastion, Bastion.Repo,
  username: "bastion",
  password: "bastion",
  hostname: "localhost",
  port: 5434,
  database: "bastion_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :bastion, BastionWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "BZr96sKxBuWTaEQJfwAY7hyoTjMHhzfTP4VwzwwYmPU7kC4LUKKXkLUjTsCPPl94",
  server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :phoenix,
  sort_verified_routes_query_params: true

config :bastion, Bastion.PKI,
  data_dir: Path.expand("../tmp/test/pki", __DIR__),
  ca_passphrase: "test-passphrase",
  kdf_iterations: 1_000

config :argon2_elixir, t_cost: 1, m_cost: 8

config :bastion, Bastion.Link, listen: false

config :bastion, Bastion.Discovery, mode: :off
