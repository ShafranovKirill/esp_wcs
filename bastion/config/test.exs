import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
# Та же БД из docker-compose.yml, что и для разработки, но своя база
config :bastion, Bastion.Repo,
  username: "bastion",
  password: "bastion",
  hostname: "localhost",
  port: 5434,
  database: "bastion_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :bastion, BastionWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "BZr96sKxBuWTaEQJfwAY7hyoTjMHhzfTP4VwzwwYmPU7kC4LUKKXkLUjTsCPPl94",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Центр сертификации в тестах: свой каталог, быстрый вывод ключа
config :bastion, Bastion.PKI,
  data_dir: Path.expand("../tmp/test/pki", __DIR__),
  ca_passphrase: "test-passphrase",
  kdf_iterations: 1_000

# Argon2 в тестах — быстрый (в работе — параметры по умолчанию)
config :argon2_elixir, t_cost: 1, m_cost: 8
