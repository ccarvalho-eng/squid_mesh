<div align="center">
  <h2>🦑 Squid Mesh</h2>

  <p><i>Workflow automation platform for Elixir applications.</i></p>

  <p>
    <a href="https://github.com/ccarvalho-eng/squid_mesh/actions/workflows/ci.yml">
      <img alt="CI" src="https://github.com/ccarvalho-eng/squid_mesh/actions/workflows/ci.yml/badge.svg" />
    </a>
    <a href="https://hex.pm/packages/squid_mesh">
      <img alt="Hex" src="https://img.shields.io/hexpm/v/squid_mesh" alt="Hex.pm"/></a>
    </a>
    <a href="https://hexdocs.pm/squid_mesh">
      <img alt="HexDocs" src="https://img.shields.io/badge/docs-hexdocs-purple" />
    </a>
    <a href="https://elixirforum.com/t/squid-mesh-workflow-automation-runtime-for-elixir-applications/75162">
      <img alt="Elixir Forum" src="https://img.shields.io/badge/Elixir_Forum-Join_Discussion-4B275F?logo=elixir&logoColor=white" />
    </a>
    <a href="https://github.com/ccarvalho-eng/squid_mesh/blob/main/LICENSE">
      <img alt="License: Apache 2.0" src="https://img.shields.io/badge/license-Apache%202.0-blue.svg" />
    </a>
  </p>
</div>

Squid Mesh lets Phoenix and OTP applications define, run, inspect, replay, and
recover durable workflows in code.

> [!WARNING]
> Squid Mesh is still in early development. The runtime is suitable for
> evaluation, local development, and integration work, but it is not yet
> positioned as production-ready. See
> [Production Readiness](docs/production_readiness.md) for the current
> checklist and remaining bar.

## Quick Start

Requirements:

- an existing Elixir application
- an existing Ecto `Repo`
- Postgres for persisted runtime state
- an existing `Oban` setup for background execution

### 1. Install from Hex.pm

```elixir
defp deps do
  [
    {:squid_mesh, "~> 0.1.0-alpha.1"}
  ]
end
```

If the host app defines custom steps with `use Jido.Action`, add `:jido`
explicitly as well:

```elixir
defp deps do
  [
    {:jido, "~> 2.0"},
    {:squid_mesh, "~> 0.1.0-alpha.1"}
  ]
end
```

### 2. Configure Squid Mesh and Oban

```elixir
config :squid_mesh,
  repo: MyApp.Repo,
  execution: [
    name: Oban,
    queue: :squid_mesh
  ]

config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [squid_mesh: 10]
```

The host app's `Oban` config must include the `:squid_mesh` queue when Squid
Mesh is using that queue name.

### 3. Install migrations

```sh
mix deps.get
mix squid_mesh.install
mix ecto.migrate
```

`mix squid_mesh.install` copies only Squid Mesh tables into the host app's
`priv/repo/migrations`. The host app still owns its `Oban` setup and
`oban_jobs` migration.

### 4. Go deeper

Use the docs index for setup, workflow authoring, operations, and architecture:

- [Docs index](docs/index.md)
- [Host app integration](docs/host_app_integration.md)
- [Workflow authoring guide](docs/workflow_authoring.md)
- [Example host app](examples/minimal_host_app/README.md)

## Contributing

- [Contributing guide](CONTRIBUTING.md)
- [Code of conduct](CODE_OF_CONDUCT.md)
