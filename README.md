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

> <i>The name blends a squid’s coordinated arms with a mesh of connected
> workflow steps, capturing the idea of orchestrating many moving parts without
> rebuilding the coordination layer in every app.</i>

> [!WARNING]
> Squid Mesh is still in early development. The runtime is suitable for
> evaluation, local development, and integration work, but it is not yet
> positioned as production-ready. See
> [Production Readiness](docs/production_readiness.md) for the current
> checklist and remaining bar.

## What You Get

- declarative workflows with manual and cron triggers
- durable run, step, and attempt history in Postgres
- step-level retries, delays, replay, and inspection on top of your existing `Oban`
- built-in steps like `:log`, `:wait`, and `:pause`, plus custom steps with `Jido.Action`

## Runtime Shape

- Squid Mesh owns workflow structure, payload validation, runtime state, and retry policy
- Oban owns durable execution, queueing, delayed scheduling, and redelivery
- your host app keeps its existing `Repo`, `Oban`, and application boundaries

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
    {:squid_mesh, "~> 0.1.0-alpha.2"}
  ]
end
```

If the host app defines custom steps with `use Jido.Action`, add `:jido`
explicitly as well:

```elixir
defp deps do
  [
    {:jido, "~> 2.0"},
    {:squid_mesh, "~> 0.1.0-alpha.2"}
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

## Example: Daily RSS To Discord

This kind of workflow is where Squid Mesh gets interesting: one cron trigger,
typed payload defaults, built-in steps, custom steps, explicit failure routing,
and step-level retry on the side effect that actually needs it.

```elixir
defmodule Content.Workflows.PostDailyDigest do
  use SquidMesh.Workflow

  workflow do
    trigger :daily_digest do
      cron("0 9 * * 1-5", timezone: "Etc/UTC")

      payload do
        field(:feed_url, :string, default: "https://example.com/feed.xml")
        field(:discord_webhook_url, :string)
        field(:posted_on, :string, default: {:today, :iso8601})
      end
    end

    step(:fetch_feed, Content.Steps.FetchFeed, output: :feed)
    step(:build_digest, Content.Steps.BuildDigest,
      input: [:feed, :posted_on],
      output: :digest
    )
    step(:announce_post, :log, message: "Posting digest to Discord", level: :info)
    step(:record_failed_delivery, Content.Steps.RecordFailedDelivery)

    step(:post_to_discord, Content.Steps.PostToDiscord,
      input: [:digest, :discord_webhook_url],
      retry: [max_attempts: 5, backoff: [type: :exponential, min: 1_000, max: 30_000]]
    )

    transition(:fetch_feed, on: :ok, to: :build_digest)
    transition(:build_digest, on: :ok, to: :announce_post)
    transition(:announce_post, on: :ok, to: :post_to_discord)
    transition(:post_to_discord, on: :ok, to: :complete)
    transition(:post_to_discord, on: :error, to: :record_failed_delivery)
    transition(:record_failed_delivery, on: :ok, to: :complete)
  end
end
```

The step modules can stay small and domain-focused, while Squid Mesh handles
durable state, scheduling through Oban, retries, failure routing after retry
exhaustion, and run inspection.

For manual review gates, use the built-in `:pause` step in transition-based
workflows and later resume the run through `SquidMesh.unblock_run/2`.

When a step needs a narrower contract than the whole payload plus accumulated
context, use `input: [...]` to select keys and `output: :key` to namespace the
returned map for downstream steps.

Start the workflow through the public API and inspect the result with history:

```elixir
{:ok, run} =
  SquidMesh.start_run(Content.Workflows.PostDailyDigest, %{
    discord_webhook_url: webhook_url
  })

SquidMesh.inspect_run(run.id, include_history: true)
```

With history enabled, the inspected run includes both chronological `step_runs`
and a graph-aware `steps` view so host apps can render dependency workflows in a
useful order.

## Documentation

Use the docs index for setup, workflow authoring, operations, and architecture:

- [Docs index](docs/index.md)
- [Host app integration](docs/host_app_integration.md)
- [Workflow authoring guide](docs/workflow_authoring.md)
- [Example host app](examples/minimal_host_app/README.md)

## Contributing

- [Contributing guide](CONTRIBUTING.md)
- [Code of conduct](CODE_OF_CONDUCT.md)
