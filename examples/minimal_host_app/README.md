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
- run the example app's `Oban` migration
- run Squid Mesh's library migrations into the same database

## Smoke Path

Run the fast smoke path without Postgres:

```sh
MIX_ENV=test mix example.smoke
```

Run the Postgres-backed path after `mix setup`:

```sh
mix example.smoke
```

The smoke task starts a payment recovery workflow through
`MinimalHostApp.WorkflowRuns.start_payment_recovery/1`, then immediately
inspects it through `MinimalHostApp.WorkflowRuns.inspect_payment_recovery/1`.

## Example Boundary

The host-facing boundary is:

```elixir
MinimalHostApp.WorkflowRuns.start_payment_recovery(%{
  account_id: "acct_123",
  invoice_id: "inv_456",
  attempt_id: "attempt_789"
})
```
