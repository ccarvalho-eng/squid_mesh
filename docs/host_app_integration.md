# Host App Integration

This document defines the initial integration contract for:

- Phoenix applications
- OTP applications with an existing `Repo`
- existing installations that already run background jobs

## Installation

Add `:squid_mesh` to the host application's dependencies and fetch dependencies
as usual with Mix.

## Configuration

The host application configures Squid Mesh under the `:squid_mesh` application:

```elixir
config :squid_mesh,
  repo: MyApp.Repo,
  execution: [
    name: Oban,
    queue: :squid_mesh
  ]
```

Required keys:

- `:repo` - the Ecto repo Squid Mesh uses for persisted runtime state

Optional keys:

- `:execution` - execution system settings
- `:execution[:name]` - the background job system name to target
- `:execution[:queue]` - queue used for Squid Mesh jobs, defaults to `:squid_mesh`

## Existing Application Setup

For an existing Phoenix or OTP application:

1. Add the `:squid_mesh` dependency.
2. Configure `:repo` to point at the app's existing repo.
3. Configure `:execution` to point at the app's existing background job setup.
4. Call `SquidMesh.config!/0` during boot or integration setup to verify the
   required contract is present.
5. Integrate Squid Mesh from the host application's contexts, services,
   controllers, or internal APIs.

The host application is responsible for:

- database setup and migrations
- background job infrastructure lifecycle
- any HTTP or internal API endpoints exposed to end users

## Development Setup

For local development and examples, a minimal host app can provide:

- a local Postgres-backed repo
- a local background job setup
- direct application code calls into Squid Mesh

This uses the same configuration contract as an existing application setup.

## Validation

Host applications can validate the contract directly:

```elixir
{:ok, config} = SquidMesh.config()
```

Or raise on missing required keys:

```elixir
config = SquidMesh.config!()
```

## Example Development Harness

The example host app smoke-test harness builds on this same contract and is the
reference setup for end-to-end development and verification.

Path:

- `examples/minimal_host_app`

Suggested workflow:

1. Start Postgres for the example app.
2. Run `mix setup` inside `examples/minimal_host_app`.
3. Run `mix example.smoke` to exercise the host app boundary.

Fast verification path:

- run `MIX_ENV=test mix example.smoke` inside `examples/minimal_host_app`

The example app wires:

- its own `MinimalHostApp.Repo`
- its own `Oban` instance
- Squid Mesh through `MinimalHostApp.WorkflowRuns`
