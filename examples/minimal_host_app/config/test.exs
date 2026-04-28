import Config

config :minimal_host_app,
  runtime_children: []

config :squid_mesh,
  repo: MinimalHostApp.TestSupport.FakeRepo,
  execution: [
    name: Oban,
    queue: :squid_mesh
  ]
