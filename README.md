<div align="center">
  <h2>Squid Mesh</h2>

  <p><i>Workflow automation platform for Elixir applications.</i></p>

  <p>
    <a href="https://github.com/ccarvalho-eng/squid_mesh/actions/workflows/ci.yml">
      <img alt="CI" src="https://github.com/ccarvalho-eng/squid_mesh/actions/workflows/ci.yml/badge.svg" />
    </a>
    <a href="https://hex.pm/packages/squid_mesh">
      <img alt="Hex" src="https://img.shields.io/hexpm/v/squid_mesh.svg" />
    </a>
    <a href="https://hexdocs.pm/squid_mesh">
      <img alt="HexDocs" src="https://img.shields.io/badge/hex-docs-blue.svg" />
    </a>
    <a href="https://github.com/ccarvalho-eng/squid_mesh/blob/main/LICENSE">
      <img alt="License: Apache 2.0" src="https://img.shields.io/badge/license-Apache%202.0-blue.svg" />
    </a>
  </p>
</div>

Squid Mesh lets Phoenix and OTP applications define, run, inspect, replay, and
recover durable workflows in code.

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
- step modules that can run as Jido actions

### 1. Add the dependency

```elixir
defp deps do
  [
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

`mix squid_mesh.install` copies only Squid Mesh tables into
`priv/repo/migrations`. It does not manage `oban_jobs`; embedded applications
are expected to use their own existing `Oban` setup.

If you are wiring Squid Mesh into a fresh app rather than an existing one, add
the host app's `Oban` migration first:

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
       MyApp.Workflows.DailyStandup
     ]}
  ],
  queues: [squid_mesh: 10]
```

`SquidMesh.Plugins.Cron` uses Oban's cron scheduler underneath. Squid Mesh does
not run a separate scheduler or manage `oban_jobs` itself.

## Runtime Overview

- Squid Mesh owns workflow structure, run state, retries, replay, and inspection.
- Oban owns durable execution, scheduling, and job redelivery.
- Jido provides the action contract for custom workflow steps.
- Postgres stores runs, step runs, attempts, and queued execution state.

Squid Mesh does not try to re-implement worker coordination that Oban already
provides. The runtime stays focused on workflow semantics and durable run state.

## Workflow Example

```elixir
defmodule Billing.Workflows.PaymentRecovery do
  use SquidMesh.Workflow

  workflow do
    trigger :payment_recovery do
      manual()

      payload do
        field(:account_id, :string)
        field(:invoice_id, :string)
        field(:attempt_id, :string)
        field(:gateway_url, :string)
      end
    end

    step(:load_invoice, Billing.Steps.LoadInvoice)
    step(:wait_for_settlement, :wait, duration: 5_000)
    step(:log_recovery_attempt, :log,
      message: "Invoice loaded, checking gateway status",
      level: :info
    )
    step(:check_gateway_status, Billing.Steps.CheckGatewayStatus,
      retry: [max_attempts: 5, backoff: [type: :exponential, min: 1_000, max: 30_000]]
    )
    step(:notify_customer, Billing.Steps.NotifyCustomer)

    transition(:load_invoice, on: :ok, to: :wait_for_settlement)
    transition(:wait_for_settlement, on: :ok, to: :log_recovery_attempt)
    transition(:log_recovery_attempt, on: :ok, to: :check_gateway_status)
    transition(:check_gateway_status, on: :ok, to: :notify_customer)
    transition(:notify_customer, on: :ok, to: :complete)
  end
end
```

## Step Example

```elixir
defmodule Billing.Steps.CheckGatewayStatus do
  use Jido.Action,
    name: "check_gateway_status",
    description: "Checks gateway state",
    schema: [
      invoice: [type: :map, required: true],
      gateway_url: [type: :string, required: true]
    ]

  @impl true
  def run(%{invoice: invoice, gateway_url: gateway_url}, _context) do
    case SquidMesh.Tools.invoke(SquidMesh.Tools.HTTP, %{
           method: :get,
           url: gateway_url,
           timeout: 1_000
         }) do
      {:ok, result} ->
        {:ok,
         %{
           gateway_check: %{
             status: result.payload.body,
             invoice_id: invoice.id,
             status_code: result.payload.status
           }
         }}

      {:error, error} ->
        {:error, SquidMesh.Tools.Error.to_map(error)}
    end
  end
end
```

## Call It From Your App

```elixir
defmodule Billing.WorkflowRuns do
  def start_payment_recovery(account_id, invoice_id, attempt_id) do
    SquidMesh.start_run(Billing.Workflows.PaymentRecovery, :payment_recovery, %{
      account_id: account_id,
      invoice_id: invoice_id,
      attempt_id: attempt_id,
      gateway_url: "https://gateway.internal/checks/#{attempt_id}"
    })
  end

  def inspect_payment_recovery(run_id) do
    SquidMesh.inspect_run(run_id)
  end

  def list_recent_payment_recoveries do
    SquidMesh.list_runs(workflow: Billing.Workflows.PaymentRecovery, limit: 20)
  end

  def cancel_payment_recovery(run_id) do
    SquidMesh.cancel_run(run_id)
  end

  def replay_payment_recovery(run_id) do
    SquidMesh.replay_run(run_id)
  end
end
```

If a workflow defines a single trigger, `SquidMesh.start_run/2` remains the
short path and uses that default trigger automatically.

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
- [Operations guide](docs/operations.md)
- [Tool adapters](docs/tool_adapters.md)
- [Observability](docs/observability.md)
- [Architecture](docs/architecture.md)
- [Production readiness](docs/production_readiness.md)
- [ADR index](docs/adr/index.md)
- [Example host app harness](examples/minimal_host_app/README.md)

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
