# Minimal Host App

Reference host-app harness for Squid Mesh.

This example shows how an application can:

- configure Squid Mesh with its own `Repo` and `Oban`
- expose workflow operations through an application-facing module
- pause and resume a human-in-the-loop workflow through that boundary
- activate cron workflows through the host app's Oban plugins
- run repeatable smoke, resilience, and bounded soak paths during development

## Setup

Start a local Postgres instance and point `DATABASE_URL` at it. The default is:

```sh
ecto://postgres:postgres@localhost/minimal_host_app_dev
```

Then set up the example app:

```sh
mix setup
```

This will:

- create the example app database
- install Squid Mesh migrations into the example app with `mix squid_mesh.install`
- run the example app's `Oban` migration
- run both the example app and Squid Mesh migrations through `mix ecto.migrate`

This example is the standalone development harness. Unlike the embedded host-app
install path, it owns its own `Oban` migration so the runtime can be exercised
without depending on another application.

## Smoke Path

Run the test-mode smoke path:

```sh
MIX_ENV=test mix example.smoke
```

This command creates the test database if needed, runs migrations, starts the
repo and Oban, starts a local HTTP gateway stub, then runs the example smoke
path to completion.

Run the development-like path after `mix setup`:

```sh
mix example.smoke
```

The smoke task:

- starts a manual payment recovery workflow through
  `MinimalHostApp.WorkflowRuns.start_payment_recovery/1`
- starts the dependency-based recovery workflow through
  `MinimalHostApp.WorkflowRuns.start_dependency_recovery/1`
- starts a manual approval workflow through
  `MinimalHostApp.WorkflowRuns.start_manual_approval/1`
- approves the paused run through `MinimalHostApp.WorkflowRuns.approve_run/2`
- waits for execution and inspects all three completed manual workflows
- activates the example cron workflow through the host app's Oban-backed cron plugin
- verifies the cron-triggered run completes as well

## Restart Resilience

Run the restart resilience verification:

```sh
MIX_ENV=test mix example.resilience
```

This path verifies:

- queued work survives an Oban restart boundary
- delayed work survives an Oban restart boundary
- retrying work survives an Oban restart boundary
- a paused manual-approval run survives restart and still approves through the host boundary with the same resume semantics

## Bounded Soak And Load

Run the bounded soak and load verification:

```sh
MIX_ENV=test mix example.soak
```

This path is intentionally not a benchmark. It drives a bounded mix of:

- concurrent successful workflow runs
- retried workflow runs
- replayed workflow runs
- cancelled workflow runs

## Example Boundary

The host-facing boundary is:

```elixir
MinimalHostApp.WorkflowRuns.start_payment_recovery(%{
  account_id: "acct_123",
  invoice_id: "inv_456",
  attempt_id: "attempt_789",
  gateway_url: "http://127.0.0.1:4010/gateway"
})
```

That map is the workflow payload for the `:payment_recovery` trigger declared
in the example workflow.

The reference workflow and step modules live in:

- `lib/minimal_host_app/workflows/payment_recovery.ex`
- `lib/minimal_host_app/workflows/dependency_recovery.ex`
- `lib/minimal_host_app/workflows/manual_approval.ex`
- `lib/minimal_host_app/workflows/daily_digest.ex`
- `lib/minimal_host_app/steps/`

## Dependency Workflow Example

The example app also includes a dependency-based workflow with two roots and a
join step:

```elixir
defmodule MinimalHostApp.Workflows.DependencyRecovery do
  use SquidMesh.Workflow

  workflow do
    trigger :dependency_recovery do
      manual()

      payload do
        field(:account_id, :string)
        field(:invoice_id, :string)
        field(:attempt_id, :string)
      end
    end

    step(:load_account, MinimalHostApp.Steps.LoadAccount)
    step(:load_invoice, MinimalHostApp.Steps.LoadInvoice)
    step(:prepare_notification, MinimalHostApp.Steps.PrepareNotification,
      after: [:load_account, :load_invoice]
    )
  end
end
```

This workflow is exercised through `MinimalHostApp.WorkflowRuns.start_dependency_recovery/1`
and the example app test suite. Ready dependency roots still execute one at a
time today; `after: [...]` guarantees that the join step waits for both inputs.
