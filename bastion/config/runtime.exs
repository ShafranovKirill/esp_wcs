import Config
import Dotenvy

env_dir = System.get_env("BASTION_ENV_DIR") || File.cwd!()
source!([Path.join(env_dir, ".env"), System.get_env()])

if System.get_env("PHX_SERVER") do
  config :bastion, BastionWeb.Endpoint, server: true
end

if config_env() == :dev do
  config :bastion, BastionWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        ~r"priv/gettext/.*\.po$"E,
        ~r"lib/bastion_web/router\.ex$"E,
        ~r"lib/bastion_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() in [:dev, :prod] do
  config :bastion, Bastion.Link, port: env!("BASTION_LINK_PORT", :integer, 7443)

  config :bastion, Bastion.Discovery,
    mode: env!("BASTION_MDNS", :string, "auto"),
    https_port: env!("BASTION_HTTPS_PORT", :integer, 443)

  config :bastion, Bastion.PKI,
    data_dir: env!("BASTION_DATA_DIR", :string, "data"),
    ca_passphrase: env!("BASTION_CA_PASSPHRASE", :string!),
    extra_hosts:
      env!("BASTION_HOSTS", :string, "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
end

if config_env() in [:dev, :prod] do
  config :bastion, :admin,
    username: env!("BASTION_ADMIN_USERNAME", :string, "admin"),
    password: env!("BASTION_ADMIN_PASSWORD", :string, nil)
end

if config_env() == :dev do
  config :bastion, Bastion.Repo, url: env!("DATABASE_URL", :string!)
end

if config_env() == :prod do
  database_url = env!("DATABASE_URL", :string!)

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :bastion, Bastion.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base = env!("SECRET_KEY_BASE", :string!)

  host = env!("PHX_HOST", :string, "bastion.local")

  config :bastion, BastionWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    https: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: env!("BASTION_HTTPS_PORT", :integer, 443),
      cipher_suite: :strong
    ],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: env!("BASTION_HTTP_PORT", :integer, 80)],
    check_origin: :conn,
    secret_key_base: secret_key_base
end
