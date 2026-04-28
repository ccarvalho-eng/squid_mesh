<div align="center">
  <img width="340" alt="logo" src="https://github.com/user-attachments/assets/22c973ae-5d03-4aaf-99c9-75640e985f1e" />

  <p><i>Workflow automation platform for Elixir applications.</i></p>

  [![CI](https://github.com/ccarvalho-eng/squid_mesh/actions/workflows/ci.yml/badge.svg)](https://github.com/ccarvalho-eng/squid_mesh/actions/workflows/ci.yml)
  [![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
</div>

Squid Mesh lets Phoenix and OTP applications define, run, inspect, and replay
durable workflows in code.

## Requirements

- an existing Elixir application
- an existing Ecto `Repo`
- Postgres for persisted runtime state
- an existing `Oban` setup for background execution
- Elixir step modules that can run as Jido actions

## Installation

For local development against a checkout, add Squid Mesh to your host
application's dependencies:

```elixir
defp deps do
  [
    {:squid_mesh, path: "../squid_mesh"}
  ]
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

## How It Fits Together
    
- Squid Mesh defines workflow structure, run state, retries, replay, and inspection.
- Oban handles durable background execution of workflow steps.
- Jido powers step behavior and action execution inside the runtime.
- Postgres stores the durable source of truth for runs, steps, and attempts.  
    
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
      end
    end

    step(:load_invoice, Billing.Steps.LoadInvoice)
    step(:wait_for_settlement, :wait, duration: 5_000)
    step(:log_recovery_attempt, :log,
      message: "Invoice loaded, checking gateway status",
      level: :info
    )
    step(:check_gateway_status, Billing.Steps.CheckGatewayStatus,
      retry: [max_attempts: 5]
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
      invoice: [type: :map, required: true]
    ]

  @impl true
  def run(%{invoice: invoice}, _context) do
    {:ok, %{gateway_check: %{status: "retry_required", invoice_id: invoice.id}}}
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
      attempt_id: attempt_id
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

The same workflow can mix custom step modules and built-in primitives:

- module steps for domain behavior and external integrations
- `:wait` for timed pauses between steps
- `:log` for durable, declarative operational markers in the flow

Run lifecycle states currently include:

- `pending`
- `running`
- `retrying`
- `failed`
- `completed`
- `cancelling`
- `cancelled`

## Getting Started

- [Host app integration](docs/host_app_integration.md)
- [Example host app harness](examples/minimal_host_app/README.md)

Fast local smoke path:

```sh
cd examples/minimal_host_app
MIX_ENV=test mix example.smoke
```
