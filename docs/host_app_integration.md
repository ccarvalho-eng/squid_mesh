# Host App Integration

This document defines the initial integration contract for:

- Phoenix applications
- OTP applications with an existing `Repo`
- existing installations that already run background jobs

## Tested Toolchain

Current CI and onboarding smoke tests run with:

- Erlang/OTP `28.4.1`
- Elixir `1.19.5-otp-28`
- `Oban 2.21` and `2.22`
- `Jido 2.0+`

## Installation

Add `:squid_mesh` to the host application's dependencies and fetch dependencies
as usual with Mix.

Preferred Hex dependency:

```elixir
defp deps do
  [
    {:squid_mesh, "~> 0.1.0-alpha.2"}
  ]
end
```

If the host app defines custom steps with `use Jido.Action`, add `:jido`
explicitly to the host app as well rather than relying on a transitive
dependency:

```elixir
defp deps do
  [
    {:jido, "~> 2.0"},
    {:squid_mesh, "~> 0.1.0-alpha.2"}
  ]
end
```

Then install Squid Mesh's library-owned migrations into the host app:

```sh
mix squid_mesh.install
mix ecto.migrate
```

`mix squid_mesh.install` copies Squid Mesh migrations into the host
application's `priv/repo/migrations` directory. It does not install or run
`Oban` migrations.

For a fresh host app, add the host app's own `Oban` migration before running
`mix ecto.migrate`:

```elixir
defmodule MyApp.Repo.Migrations.AddObanJobs do
  use Ecto.Migration

  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down()
end
```

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

The host application's `Oban` config must also include the queue Squid Mesh is
configured to use. For the default queue name:

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [squid_mesh: 10]
```

Required keys:

- `:repo` - the Ecto repo Squid Mesh uses for persisted runtime state

Optional keys:

- `:execution` - execution system settings
- `:execution[:name]` - the background job system name to target
- `:execution[:queue]` - queue used for Squid Mesh jobs, defaults to `:squid_mesh`
- `:execution[:stale_step_timeout]` - milliseconds before a redelivered running
  step can be reclaimed after worker interruption, defaults to `900_000`

## First Run Checklist

For a new integration, the shortest path to a successful first run is:

1. Add `:squid_mesh` to the host app's dependencies.
2. Add or confirm a working Postgres-backed `Repo`.
3. Add or confirm a working `Oban` instance.
4. Add the host app's `Oban` migration if the app does not already have `oban_jobs`.
5. Run `mix squid_mesh.install`.
6. Run `mix ecto.migrate`.
7. Configure `:squid_mesh` with the host app's `Repo` and `Oban` queue.
8. Configure the host app's `Oban` queues to include `:squid_mesh`.
9. Start the host app's `Repo` and `Oban` under supervision.
10. Start one workflow through the public API and inspect it with history enabled.

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

That means the embedded install path assumes:

- the host app already owns its `Repo`
- the host app already owns its `Oban` configuration
- the host app already manages its `oban_jobs` table

## Minimal OTP Host Skeleton

For a plain OTP application, the minimum moving pieces are:

- a `Repo` module
- an `Oban` configuration
- `Repo` and `Oban` in the application supervision tree
- `:squid_mesh` configuration pointing at that `Repo` and queue
- one host-facing module that calls `SquidMesh`

Dependency shape:

```elixir
defp deps do
  [
    {:ecto_sql, "~> 3.13"},
    {:postgrex, "~> 0.20"},
    {:oban, "~> 2.21"},
    {:jido, "~> 2.0"},
    {:squid_mesh, "~> 0.1.0-alpha.2"}
  ]
end
```

Application supervision shape:

```elixir
children = [
  MyApp.Repo,
  {Oban, Application.fetch_env!(:my_app, Oban)}
]
```

Host-facing boundary:

```elixir
defmodule MyApp.WorkflowRuns do
  def start_payment_recovery(payload) do
    SquidMesh.start_run(MyApp.Workflows.PaymentRecovery, :payment_recovery, payload)
  end

  def inspect_run(run_id) do
    SquidMesh.inspect_run(run_id, include_history: true)
  end

  def unblock_run(run_id, attrs \\ %{}) do
    SquidMesh.unblock_run(run_id, attrs)
  end

  def approve_run(run_id, attrs) do
    SquidMesh.approve_run(run_id, attrs)
  end

  def reject_run(run_id, attrs) do
    SquidMesh.reject_run(run_id, attrs)
  end
end
```

If the host app exposes pause-resume or approval workflows, keep the latest
Squid Mesh migrations applied before deploying the feature. Paused step runs
now persist internal resume metadata so `unblock_run/2`, `approve_run/3`, and
`reject_run/3` can continue with stable output and transition semantics after
restarts or code changes.

Operational review shape:

```elixir
{:ok, paused_run} = MyApp.WorkflowRuns.inspect_run(run_id)

Enum.map(paused_run.audit_events, &{&1.type, &1.step})
#=> [{:paused, :wait_for_review}]

{:ok, _run} =
  MyApp.WorkflowRuns.approve_run(run_id, %{
    actor: "ops_123",
    comment: "customer verified",
    metadata: %{ticket: "SUP-42"}
  })

{:ok, completed_run} = MyApp.WorkflowRuns.inspect_run(run_id)

Enum.map(completed_run.audit_events, &{&1.type, &1.actor, &1.comment})
#=> [{:paused, nil, nil}, {:approved, "ops_123", "customer verified"}]
```

`include_history: true` is the public audit boundary. With history enabled, the
run includes chronological `step_runs`, graph-aware `steps`, and durable
`audit_events` for pause, resume, approval, and rejection actions.

## Minimal Phoenix Host Skeleton

A Phoenix application uses the same runtime contract. The main difference is
that Squid Mesh usually sits behind a context or controller boundary.

Typical shape:

- add `:squid_mesh`, `:oban`, and `:jido` to the Phoenix app
- keep using the Phoenix app's existing `Repo`
- start `Oban` in the application supervision tree
- configure `:squid_mesh` to use that `Repo` and queue
- expose workflow operations through a context or controller

Context boundary:

```elixir
defmodule MyApp.WorkflowRuns do
  def start_payment_recovery(attrs) do
    SquidMesh.start_run(MyApp.Workflows.PaymentRecovery, :payment_recovery, attrs)
  end

  def inspect_run(run_id) do
    SquidMesh.inspect_run(run_id, include_history: true)
  end

  def unblock_run(run_id, attrs \\ %{}) do
    SquidMesh.unblock_run(run_id, attrs)
  end

  def approve_run(run_id, attrs) do
    SquidMesh.approve_run(run_id, attrs)
  end

  def reject_run(run_id, attrs) do
    SquidMesh.reject_run(run_id, attrs)
  end

  def list_runs(opts \\ []) do
    SquidMesh.list_runs(opts)
  end
end
```

Controller shape:

```elixir
def create(conn, params) do
  with {:ok, run} <- MyApp.WorkflowRuns.start_payment_recovery(params) do
    json(conn, %{id: run.id, status: run.status})
  end
end
```

## Development Setup

For local development and examples, a minimal host app can provide:

- a local Postgres-backed repo
- a local background job setup
- direct application code calls into Squid Mesh

This uses the same configuration contract as an existing application setup.
In that mode, the example app may also own its own `Oban` migration because it
is acting as a standalone development harness rather than an embedded install.

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

## Inspecting History

For real host apps, `inspect_run/2` is most useful with history enabled:

```elixir
SquidMesh.inspect_run(run_id, include_history: true)
```

That returns the top-level run plus:

- `steps`: logical per-step state in workflow order, including dependency edges
- `step_runs`: persisted execution history
- `attempts`: persisted retry history for each step run

This split lets host apps render both a graph-oriented status view and the raw
execution timeline from one inspection call.
