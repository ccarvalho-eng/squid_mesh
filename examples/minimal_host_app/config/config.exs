import Config

config :minimal_host_app,
  ecto_repos: [MinimalHostApp.Repo]

config :minimal_host_app, MinimalHostApp.Repo,
  url: System.get_env("DATABASE_URL", "ecto://postgres:postgres@localhost/minimal_host_app_dev"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
  show_sensitive_data_on_connection_error: true,
  stacktrace: true

config :minimal_host_app, Oban,
  repo: MinimalHostApp.Repo,
  plugins: [],
  queues: [squid_mesh: 5]

config :squid_mesh,
  repo: MinimalHostApp.Repo,
  execution: [
    name: Oban,
    queue: :squid_mesh
  ]

import_config "#{config_env()}.exs"
