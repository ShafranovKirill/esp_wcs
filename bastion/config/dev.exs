import Config

config :bastion, Bastion.Repo,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :bastion, BastionWeb.Endpoint,
  https: [ip: {127, 0, 0, 1}, port: 4443, cipher_suite: :strong],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "EfvIR2oImDQt8pJUwjp+s+iPhL6MwLI+QllVc1iduA+d1G1xcFBRs6NhkuU+qQXx",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:bastion, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:bastion, ~w(--watch)]}
  ]

config :bastion, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true
