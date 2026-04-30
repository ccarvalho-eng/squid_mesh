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
    <a href="https://github.com/ccarvalho-eng/squid_mesh/blob/main/LICENSE">
      <img alt="License: Apache 2.0" src="https://img.shields.io/badge/license-Apache%202.0-blue.svg" />
    </a>
  </p>
</div>

Squid Mesh lets Phoenix and OTP applications define, run, inspect, replay, and
recover durable workflows in code.

> <i>The name blends a squid’s coordinated arms with a mesh of connected workflow steps—capturing the idea of orchestrating many moving parts without rebuilding the coordination layer in every app.</i>

## Features 

- Define workflows with triggers, payload contracts, steps, transitions, and retries.
- Run them durably on top of your app's existing `Repo` and `Oban`.
- Inspect runs with step and attempt history.
- Replay, cancel, and schedule recurring runs without inventing the runtime yourself.

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
- step modules that can run as Jido actions when you want custom steps

### 1. Add the dependency

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

For direct Git evaluation:

```elixir
defp deps do
  [
    {:squid_mesh, github: "ccarvalho-eng/squid_mesh", tag: "v0.1.0-alpha.1"}
  ]
end
```

### 2. Configure Squid Mesh

```elixir
config :squid_mesh,
  repo: MyApp.Repo,
  execution: [
    name: Oban,
    queue: :squid_mesh
  ]
```

### 3. Install Squid Mesh migrations

```sh
mix deps.get
mix squid_mesh.install
mix ecto.migrate
```

`mix squid_mesh.install` copies only Squid Mesh tables into the host app's
`priv/repo/migrations`. It does not manage `oban_jobs`; embedded applications
are expected to use their own existing `Oban` setup.

If you are wiring Squid Mesh into a fresh app, add the host app's `Oban`
migration first:

```elixir
defmodule MyApp.Repo.Migrations.AddObanJobs do
  use Ecto.Migration

  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down()
end
```

### 4. Activate cron workflows if needed

Cron triggers are declared in workflows and activated through the host app's
Oban plugins:

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  plugins: [
    {SquidMesh.Plugins.Cron,
     workflows: [
       MyApp.Workflows.DailyDigest
     ]}
  ],
  queues: [squid_mesh: 10]
```

## Runtime Overview

- Squid Mesh owns workflow structure, run state, step state, retries, replay, and inspection.
- Oban owns durable execution, scheduling, and job redelivery.
- Jido provides the action contract for custom workflow steps.
- Postgres stores runs, step runs, attempts, and queued execution state.

Squid Mesh does not try to re-implement worker coordination that Oban already
provides. It records workflow state, then inserts and schedules step jobs
through Oban for first execution, step progression, and retries. Oban is the
durable execution layer underneath that flow; Squid Mesh remains the workflow
runtime and source of truth for what should happen next.

## Example Uses

- Post an RSS digest to Discord every morning.
- Turn a Linear issue into a planning workflow for your team.
- Run recovery, approval, and back-office flows inside Phoenix apps.

## Cron Workflow Example: Daily RSS To Discord

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

    step(:fetch_feed, Content.Steps.FetchFeed)
    step(:build_digest, Content.Steps.BuildDigest)
    step(:post_to_discord, Content.Steps.PostToDiscord,
      retry: [max_attempts: 5, backoff: [type: :exponential, min: 1_000, max: 30_000]]
    )

    transition(:fetch_feed, on: :ok, to: :build_digest)
    transition(:build_digest, on: :ok, to: :post_to_discord)
    transition(:post_to_discord, on: :ok, to: :complete)
  end
end
```

## Manual Workflow Example: Plan A Linear Task

```elixir
defmodule Planning.Workflows.PlanLinearTask do
  use SquidMesh.Workflow

  workflow do
    trigger :plan_task do
      manual()

      payload do
        field(:linear_issue_id, :string)
        field(:requester_id, :string)
      end
    end

    step(:load_issue, Planning.Steps.LoadLinearIssue)
    step(:draft_plan, Planning.Steps.DraftExecutionPlan)
    step(:attach_plan, Planning.Steps.AttachPlanToLinearIssue)

    transition(:load_issue, on: :ok, to: :draft_plan)
    transition(:draft_plan, on: :ok, to: :attach_plan)
    transition(:attach_plan, on: :ok, to: :complete)
  end
end
```

## Dependency Workflow Example: Join Two Preparation Steps

```elixir
defmodule Notifications.Workflows.PrepareReminder do
  use SquidMesh.Workflow

  workflow do
    trigger :prepare_reminder do
      manual()

      payload do
        field(:account_id, :string)
        field(:invoice_id, :string)
      end
    end

    step(:load_account, Notifications.Steps.LoadAccount)
    step(:load_invoice, Notifications.Steps.LoadInvoice)
    step(:prepare_notification, Notifications.Steps.PrepareNotification,
      after: [:load_account, :load_invoice]
    )
  end
end
```

Use `transition/2` when the workflow is a single ordered path and each step
chooses the next step by outcome. Use `after: [...]` when a step should wait
for one or more prerequisite steps, especially when multiple root steps fan in
to a join step.

In the example above, `:load_account` and `:load_invoice` are independent root
steps. Squid Mesh does not need a transition between them because neither one
depends on the other. Today they run one at a time in declaration order, and
`:prepare_notification` becomes runnable only after both have completed.

`after: [...]` makes a step runnable only after every named dependency
completes successfully. Omit the option entirely for root steps; `after: []` is
not valid because it changes execution semantics without adding a dependency
edge. Dependency workflows do not mix with `transition/2` in this slice.

Today, ready dependency roots still execute one at a time in phase order. The
current dependency scheduler resolves readiness from persisted step history
after each successful dependency step, so this slice is aimed at small and
medium graph workflows; parallel dispatch and larger-graph optimization are
follow-up runtime work.

## Step Example

```elixir
defmodule Content.Steps.PostToDiscord do
  use Jido.Action,
    name: "post_to_discord",
    description: "Posts the digest to Discord",
    schema: [
      discord_webhook_url: [type: :string, required: true],
      digest: [type: :string, required: true]
    ]

  @impl true
  def run(%{discord_webhook_url: webhook_url, digest: digest}, _context) do
    case SquidMesh.Tools.invoke(SquidMesh.Tools.HTTP, %{
           method: :post,
           url: webhook_url,
           json: %{content: digest}
         }) do
      {:ok, result} ->
        {:ok, %{discord_status: result.payload.status}}

      {:error, error} ->
        {:error, SquidMesh.Tools.Error.to_map(error)}
    end
  end
end
```

## Call It From Your App

```elixir
defmodule Planning.WorkflowRuns do
  def plan_linear_task(linear_issue_id, requester_id) do
    SquidMesh.start_run(Planning.Workflows.PlanLinearTask, %{
      linear_issue_id: linear_issue_id,
      requester_id: requester_id
    })
  end
end
```

If a workflow defines a single trigger, `SquidMesh.start_run/2` uses that
trigger automatically.

Inspect a run with history:

```elixir
SquidMesh.inspect_run(run_id, include_history: true)
```

Workflows can mix:
- custom step modules for domain behavior
- built-in `:wait` and `:log` steps
- tool adapters like `SquidMesh.Tools.HTTP` for normalized integrations

Retry behavior stays on the step that owns the work:

```elixir
step(:check_gateway_status, Billing.Steps.CheckGatewayStatus,
  retry: [max_attempts: 5, backoff: [type: :exponential, min: 1_000, max: 30_000]]
)
```
## Operational Boundaries

Current guarantees:
- runs, steps, and attempts are durable in Postgres
- queued and scheduled work survives restarts through Oban
- retry, replay, inspection, and cancellation operate on persisted run state

Current non-goals:
- exactly-once external effects without idempotent step design
- custom worker leases or heartbeats beyond Oban
- dynamic cron registration after boot

## Documentation

- [HexDocs](https://hexdocs.pm/squid_mesh)
- [Compatibility matrix](docs/compatibility.md)
- [Workflow authoring guide](docs/workflow_authoring.md)
- [Host app integration](docs/host_app_integration.md)
- [Architecture](docs/architecture.md)
- [Operations guide](docs/operations.md)
- [Example host app](examples/minimal_host_app/README.md)

## Contributing

- [Contributing guide](CONTRIBUTING.md)
- [Code of conduct](CODE_OF_CONDUCT.md)

For a standalone development harness with its own `Repo` and `Oban`, use
`examples/minimal_host_app`.

Fast local smoke path:

```sh
cd examples/minimal_host_app
MIX_ENV=test mix example.smoke
```
