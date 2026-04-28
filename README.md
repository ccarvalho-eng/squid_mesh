<div align="center">
  <img width="225" alt="logo" src="https://github.com/user-attachments/assets/7e6a0fd3-f836-421c-bdf6-aefbb4c77111" />

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

> [!WARNING]
> Squid Mesh is still in early development. The runtime is suitable for
> evaluation, local development, and integration work, but it is not yet
> positioned as production-ready. See
> [Production Readiness](docs/production_readiness.md) for the current
> checklist and remaining bar.

## Requirements

- an existing Elixir application
- an existing Ecto `Repo`
- Postgres for persisted runtime state
- an existing `Oban` setup for background execution
- Elixir step modules that can run as Jido actions

## Supported Baseline

Current verified baseline:

| Component | Baseline |
| --- | --- |
| Elixir | `1.19.5-otp-28` |
| Erlang/OTP | `28.4.1` |
| Postgres | `15+` |
| Oban | `2.21` and `2.22` |
| Jido | `2.0+` |

See [Compatibility Matrix](docs/compatibility.md) for support policy details.

## Installation

Add Squid Mesh to your application's dependencies:

```elixir
defp deps do
  [
    {:squid_mesh, "~> 0.1.0-alpha.1"}
  ]
end
```

If you want to evaluate directly from Git instead of Hex:

```elixir
defp deps do
  [
    {:squid_mesh, github: "ccarvalho-eng/squid_mesh", tag: "v0.1.0-alpha.1"}
  ]
end
```

Install Squid Mesh's library-owned migrations into the host application and run
them through the host app's normal migration flow:

```sh
mix deps.get
mix squid_mesh.install
mix ecto.migrate
```

`mix squid_mesh.install` copies only Squid Mesh tables into
`priv/repo/migrations`. It does not manage `oban_jobs`; embedded applications
are expected to use their own existing `Oban` setup.

If you are wiring Squid Mesh into a fresh app rather than an existing one, add
an `Oban` migration first and run it through the host app's normal migration
flow:

```elixir
defmodule MyApp.Repo.Migrations.AddObanJobs do
  use Ecto.Migration

  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down()
end
```

## Configuration

Configure Squid Mesh under the `:squid_mesh` application:

```elixir
config :squid_mesh,
  repo: MyApp.Repo,
  execution: [
    name: Oban,
    queue: :squid_mesh
  ]
```

Public runtime API:

- `SquidMesh.start_run/2`
- `SquidMesh.start_run/3`
- `SquidMesh.start_run/4`
- `SquidMesh.inspect_run/2`
- `SquidMesh.list_runs/2`
- `SquidMesh.cancel_run/2`
- `SquidMesh.replay_run/2`

First successful run checklist:

1. Add the `:squid_mesh` dependency.
2. Make sure the host app already owns a working `Repo`.
3. Make sure the host app already owns a working `Oban` instance and `oban_jobs` table.
4. Run `mix squid_mesh.install`.
5. Run `mix ecto.migrate`.
6. Configure `:squid_mesh` with the host app's `Repo` and `Oban` queue.
7. Start the host app's `Repo` and `Oban` under supervision.
8. Start one workflow through `SquidMesh.start_run/2` or `start_run/3`.

For a standalone development harness with its own `Repo` and `Oban`, use
`examples/minimal_host_app`.

To activate cron triggers in a host app, opt in through the host app's Oban
plugins:

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

- Squid Mesh defines workflow structure, run state, retries, replay, and inspection.
- Oban handles durable execution, scheduling, and redelivery of workflow step jobs.
- Jido powers step behavior and action execution inside the runtime.
- Postgres stores the durable source of truth for runs, steps, and attempts.

Jido's role today is intentionally narrow:

- Squid Mesh uses `Jido.Action` and `Jido.Exec` as the contract for custom workflow steps.
- Host applications get validated, structured step execution without Squid Mesh having to invent its own action runtime.

Likely future direction:

- reusable step and action libraries for common integrations
- stronger action-level validation and lifecycle hooks
- richer agent and action execution patterns behind the same workflow runtime surface

### C4 Container View

```text
+--------------------------------------------------------------------------------+
| Person / System: Host Elixir or Phoenix application                            |
|                                                                                |
| - defines workflow modules with `use SquidMesh.Workflow`                       |
| - starts and inspects runs through `SquidMesh`                                 |
| - may opt into `SquidMesh.Plugins.Cron` through its Oban config                |
+---------------------------------------------+----------------------------------+
                                              |
                                              v
+--------------------------------------------------------------------------------+
| Container: Squid Mesh library                                                  |
|                                                                                |
| Responsibilities                                                               |
| - public runtime API (`SquidMesh`)                                             |
| - workflow definition + payload/trigger validation                             |
| - durable run state (`RunStore`, `StepRunStore`, `AttemptStore`)               |
| - step execution flow (`Dispatcher` -> `StepWorker` -> `StepExecutor`)         |
| - retry policy, replay/cancel semantics, built-in steps, observability         |
+-------------------------------+-----------------------------+------------------+
                                |                             |
                                v                             v
                    +-----------+-----------+     +-----------+-----------+
                    | Container: Oban       |     | Container: Jido       |
                    | durable job execution |     | executes custom step  |
                    | queues + scheduling   |     | modules               |
                    +-----------+-----------+     +-----------+-----------+
                                |                             ^
                                v                             |
                    +-----------+-----------------------------+-----------+
                    | Container: Postgres                                 |
                    | source of truth for runs, step runs, attempts,      |
                    | and Oban-managed jobs                               |
                    +-----------------------------------------------------+

External integration path:
custom workflow step -> `SquidMesh.Tools` -> adapter (for example HTTP) -> external system
```

## Execution Model

- One workflow step execution maps to one Oban job.
- Squid Mesh decides whether a step should run, retry, fail, complete, or no-op.
- Oban owns job durability, scheduling, and redelivery.
- Step retry policy is declared in the workflow and scheduled through Oban.
- Jido action retries are disabled at the Squid Mesh boundary so workflow attempts, persisted step attempts, and backoff policy stay aligned.
- Built-in `:wait` schedules delayed continuation through Oban instead of sleeping inside a worker.
- Step implementations should be idempotent when they perform external side effects.
- Tool adapters report the first transport or status failure; workflow retries stay at the step layer.

Squid Mesh does not try to re-implement worker coordination that Oban already
provides. The runtime stays focused on workflow semantics and durable run
state, while Oban remains the execution engine underneath.

## Recovery Boundaries

V1 guarantees:

- Runs, steps, and attempts are persisted in Postgres.
- Queued and scheduled step work survives deploys and restarts through Oban.
- Retry, replay, inspection, and cancellation operate on durable run state.
- Stale or duplicate step deliveries are treated as workflow-level no-ops when possible.

V1 does not claim:

- Custom heartbeats or worker leases beyond Oban's own job lifecycle.
- Automatic reclamation of an interrupted in-flight step that died mid-side-effect.
- Exactly-once delivery for external effects without idempotent step implementations.

If a workflow step talks to an external system, the step should own its own
idempotency key or duplicate-protection strategy at that boundary.

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

To inspect the run with step and attempt history:

```elixir
SquidMesh.inspect_run(run_id, include_history: true)
```

Trigger boundary today:

- `manual()` triggers are runnable through the public API
- `cron(...)` triggers are activated by opting the workflow into `SquidMesh.Plugins.Cron` under the host app's Oban configuration
- cron activation is static at boot today, matching Oban's built-in cron plugin model

Workflows can mix custom step modules and built-in primitives:

- module steps for domain behavior and external integrations
- `:wait` for delayed continuation between steps
- `:log` for durable, declarative operational markers in the flow

Workflow steps can also call tool adapters through the shared boundary:

- `SquidMesh.Tools.invoke/4` for adapter invocation
- `SquidMesh.Tools.HTTP` for normalized HTTP calls with Req
- `SquidMesh.Tools.Error.to_map/1` when a step wants to return adapter errors as workflow failures

Retry behavior stays on the step that owns the work:

```elixir
step(:check_gateway_status, Billing.Steps.CheckGatewayStatus,
  retry: [max_attempts: 5, backoff: [type: :exponential, min: 1_000, max: 30_000]]
)
```

That keeps retry policy on the step that owns the work while Squid Mesh and
Oban handle delayed rescheduling underneath.

Run lifecycle states currently include:

- `pending`
- `running`
- `retrying`
- `failed`
- `completed`
- `cancelling`
- `cancelled`

## Documentation

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

Fast local smoke path:

```sh
cd examples/minimal_host_app
MIX_ENV=test mix example.smoke
```
