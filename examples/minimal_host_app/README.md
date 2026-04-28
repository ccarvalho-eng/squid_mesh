# Minimal Host App

Reference host-app harness for Squid Mesh.

This example shows how an application can:

- configure Squid Mesh with its own `Repo` and `Oban`
- expose workflow operations through an application-facing module
- run a repeatable smoke path during development

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
repo and Oban, starts a local HTTP gateway stub, then runs the workflow to
completion.

Run the development-like path after `mix setup`:

```sh
mix example.smoke
```

The smoke task starts a payment recovery workflow through
`MinimalHostApp.WorkflowRuns.start_payment_recovery/1`, waits for execution,
and inspects the completed run through
`MinimalHostApp.WorkflowRuns.inspect_payment_recovery/1`.

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
- `lib/minimal_host_app/steps/`
