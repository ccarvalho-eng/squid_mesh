<div align="center">
  <img width="85" alt="squid-mesh" src="https://github.com/user-attachments/assets/ce1d756d-82a0-4be4-ba5b-98174557e00c" />
  <h1>Squid Mesh</h1>
  <p><i>Durable workflow runtime for Elixir applications.</i></p>

  [![CI](https://github.com/ccarvalho-eng/squid_mesh/actions/workflows/ci.yml/badge.svg)](https://github.com/ccarvalho-eng/squid_mesh/actions/workflows/ci.yml)
  [![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
</div>

Squid Mesh is a library for defining and running durable workflows inside
Phoenix and OTP applications.

## Requirements

- an existing Elixir application
- an existing Ecto `Repo`
- Postgres for persisted runtime state
- an existing `Oban` setup for background execution

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

Current runtime API:

- `SquidMesh.start_run/3`
- `SquidMesh.inspect_run/2`
- `SquidMesh.list_runs/2`
- `SquidMesh.cancel_run/2`

## Define A Workflow

```elixir
defmodule Billing.Workflows.PaymentRecovery do
  use SquidMesh.Workflow

  workflow do
    input do
      field(:account_id, :string)
      field(:invoice_id, :string)
      field(:attempt_id, :string)
    end

    step(:load_invoice, Billing.Steps.LoadInvoice)
    step(:check_gateway, Billing.Steps.CheckGatewayStatus)
    step(:notify_customer, Billing.Steps.NotifyCustomer)
    step(:open_follow_up, Billing.Steps.OpenFollowUpTask)

    transition(:load_invoice, on: :ok, to: :check_gateway)
    transition(:check_gateway, on: :retry_required, to: :notify_customer)
    transition(:notify_customer, on: :ok, to: :open_follow_up)
    transition(:open_follow_up, on: :ok, to: :complete)

    retry(:check_gateway, max_attempts: 5)
  end
end
```

## Call It From Your App

```elixir
defmodule Billing do
  def recover_failed_payment(account_id, invoice_id, attempt_id) do
    SquidMesh.start_run(Billing.Workflows.PaymentRecovery, %{
      account_id: account_id,
      invoice_id: invoice_id,
      attempt_id: attempt_id
    })
  end

  def inspect_payment_recovery(run_id) do
    SquidMesh.inspect_run(run_id)
  end

  def list_active_recoveries do
    SquidMesh.list_runs(status: :running)
  end

  def cancel_payment_recovery(run_id) do
    SquidMesh.cancel_run(run_id)
  end
end
```

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
