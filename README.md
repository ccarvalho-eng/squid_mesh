<h1>🦑 Squid Mesh</h1>

<p><strong>Durable workflow runtime for Elixir applications, running on top of Postgres and Oban.</strong></p>

<p>
  <a href="https://github.com/ccarvalho-eng/squid_mesh/actions/workflows/ci.yml">
    <img alt="CI" src="https://github.com/ccarvalho-eng/squid_mesh/actions/workflows/ci.yml/badge.svg" />
  </a>
  <a href="https://hex.pm/packages/squid_mesh">
    <img alt="Hex" src="https://img.shields.io/hexpm/v/squid_mesh" />
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

Squid Mesh is an embedded workflow runtime for Phoenix and OTP applications.
Workflow definitions cover retries, waits, approval gates, dependency joins,
failure routes, replay, and inspection. Runtime state is persisted in Postgres,
and execution is queued through Oban.

## Capabilities

- declarative workflows with manual and cron triggers
- durable run, step, and attempt history in Postgres
- step-level retries, delays, replay, and inspection on top of your existing `Oban`
- transition, dependency, and approval-style workflow shapes
- explicit step input and output mapping
- inspection of declared step state plus manual audit events for pause, resume, approval, and rejection
- built-in steps like `:log`, `:wait`, `:pause`, and `:approval`, plus custom steps with `Jido.Action`

## Fit

- a workflow should survive app restarts, deploys, retries, and Oban redelivery
- a Phoenix context needs a durable approval, recovery, notification, or back-office flow
- step history and manual decisions need to be inspectable later
- you want workflow state in your app's Postgres database, not in a separate service

> [!WARNING]
> Squid Mesh is still in early development. The runtime is suitable for
> evaluation, local development, and integration work, but it is not yet
> documented as production-ready. See
> [Production Readiness](docs/production_readiness.md) for the current
> checklist and remaining bar.

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
    {:squid_mesh, "~> 0.1.0-alpha.3"}
  ]
end
```

If the host app defines custom steps with `use Jido.Action`, add `:jido`
explicitly as well:

```elixir
defp deps do
  [
    {:jido, "~> 2.0"},
    {:squid_mesh, "~> 0.1.0-alpha.3"}
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

This example shows the core runtime shape: one cron trigger, typed payload
defaults, built-in steps, custom steps, explicit failure routing, and
step-level retry on the external side-effect step.

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

Step modules implement domain work. Squid Mesh records durable state, schedules
jobs through Oban, applies step retry policy, routes failures after retry
exhaustion, and exposes run inspection.

For approval or manual-review gates, use `approval_step/2` in transition-based
workflows and resume the paused run through `SquidMesh.approve_run/3` or
`SquidMesh.reject_run/3`. Approval steps persist their resolved `:ok` and
`:error` targets plus output-mapping metadata, so already-paused review runs
keep the same decision semantics across restarts and deploys. Generic
`SquidMesh.unblock_run/2` remains available for lower-level `:pause` steps when
you need manual intervention without an explicit approve/reject contract.

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

With history enabled, the inspected run includes chronological `step_runs`,
declared `steps` state, and durable `audit_events` for pause, resume, approval,
and rejection actions.

Use `SquidMesh.explain_run/2` when a host app needs operator-facing diagnostics:

```elixir
{:ok, explanation} = SquidMesh.explain_run(run.id)

explanation.reason
#=> :waiting_for_retry
```

`inspect_run/2` returns the persisted runtime facts. `explain_run/2` summarizes
the current reason, valid next actions, and evidence in a structured shape that
dashboards and CLIs can render themselves.

## Documentation

Use the docs index for setup, workflow authoring, operations, and architecture:

- [Docs index](docs/index.md)
- [Host app integration](docs/host_app_integration.md)
- [Workflow authoring guide](docs/workflow_authoring.md)
- [Example host app](https://github.com/ccarvalho-eng/squid_mesh/tree/main/examples/minimal_host_app)

## Contributing

- [Contributing guide](CONTRIBUTING.md)
- [Code of conduct](CODE_OF_CONDUCT.md)
