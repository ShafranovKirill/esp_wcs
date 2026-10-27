import Config

config :bastion, BastionWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

config :bastion, BastionWeb.Endpoint,
  force_ssl: [
    exclude: [
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]

config :logger, level: :info
