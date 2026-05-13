# Operations Guide

This guide covers the operational boundaries Squid Mesh expects host
applications to own.

## Runtime Guarantees

Squid Mesh currently guarantees:

- durable run, step, and attempt state in Postgres
- durable queued and scheduled work through Oban
- workflow-level retry, replay, inspection, and cancellation on top of that durable state

Squid Mesh does not currently claim:

- exactly-once external side effects
- custom worker leases or heartbeats beyond Oban
- dynamic cron registration after boot

## Idempotent Step Design

Any step that talks to an external system should be idempotent at that
boundary.

Recommended patterns:

- include an application-owned idempotency key in the external request
- persist enough domain state to detect duplicate delivery
- treat remote `409` or duplicate acknowledgements as success when appropriate
- for payment providers, pass a stable key derived from the workflow run, step,
  and domain operation rather than generating a fresh key on each attempt

Avoid:

- steps that produce irreversible side effects without a duplicate strategy
- relying on "this step should only run once" as the safety model

## Queue Sizing

Squid Mesh runs on the host app's `Oban` instance, so queue sizing stays a
host-app decision.

Recommended starting point:

- dedicate a `:squid_mesh` queue
- isolate higher-cost workflow traffic from unrelated app jobs
- size concurrency conservatively, then increase based on observed queue depth

If workflows perform mostly I/O:

- a moderate queue limit is usually fine

If workflows call slow external systems:

- keep limits lower
- prefer backoff and queue isolation over large worker counts

## Retries And Backoff

Workflow-step retries are owned by Squid Mesh, not by Oban worker
`max_attempts`.

Jido action retries are also disabled at the Squid Mesh runtime boundary so one
workflow attempt maps to one persisted step attempt.

Recommended practice:

- declare retries only on steps that own recoverable work
- prefer bounded exponential backoff
- surface structured errors from steps so retry behavior is understandable in inspection
- mark non-compensatable external side effects with `irreversible: true` or
  `compensatable: false` so replay requires explicit operator approval
- mark error transitions with `recovery: :compensation` or `recovery: :undo`
  when the operational response differs

Example:

```elixir
step :check_gateway_status, MyApp.Steps.CheckGatewayStatus,
  retry: [max_attempts: 5, backoff: [type: :exponential, min: 1_000, max: 30_000]]
```

## Compensation Versus Undo

Compensation is a forward recovery action that reconciles partial work. Undo is
a reversal of local work the application still controls. Keep those paths
explicit in the workflow so operators can tell whether a failure was reconciled
or reversed:

```elixir
transition(:capture_payment, on: :error, to: :issue_credit, recovery: :compensation)
transition(:reserve_inventory, on: :error, to: :release_inventory, recovery: :undo)
```

When Squid Mesh routes through one of these transitions, inspection history
shows the failed step's `recovery.failure` decision and emits either
`:compensation_routed` or `:undo_routed` in `audit_events`.

## Local Transaction Boundaries

`transaction: :repo` gives one custom step a same-process host repo transaction.
It is useful for local database groups that should commit or roll back together
before Squid Mesh advances the durable workflow:

```elixir
step :post_local_ledger_entries, MyApp.Steps.PostLocalLedgerEntries,
  transaction: :repo
```

Operational boundary:

- the action callback runs in the worker process inside `config.repo.transaction/1`
- `{:ok, output}` commits the host repo transaction, then Squid Mesh persists
  the step result and dispatches successors in its normal durable transaction
- `{:error, reason}` rolls back the host repo transaction, then Squid Mesh
  persists the failed step and applies retry or failure routing
- a crash after local commit but before Squid Mesh persists progress can still
  be redelivered, so local transaction groups should use natural keys,
  uniqueness, or other idempotency guards when duplicate local writes matter
- this option does not cover external APIs, downstream steps, Oban dispatch, or
  saga compensation callbacks

Keep this option for small local write groups. If a boundary crosses services,
queues, or later workflow steps, model recovery explicitly with retries,
compensation callbacks, or `:error` transitions.

## Replay After Irreversible Side Effects

Replay starts a new run from the original payload. That is useful for
recoverable workflows, but it can repeat external effects that have already
happened.

When a completed source run contains a step marked `irreversible: true` or
`compensatable: false`, Squid Mesh blocks replay by default:

```elixir
{:error, {:unsafe_replay, details}} = SquidMesh.replay_run(run_id)
```

Operator tooling should show `details.steps` and require a deliberate decision
before retrying. If the operator accepts the risk, pass the explicit override:

```elixir
SquidMesh.replay_run(run_id, allow_irreversible: true)
```

Use this path only after checking the external system or domain records. The
marker changes Squid Mesh recovery semantics; it does not make a payment,
message, shipment, or webhook idempotent.

## Stale Running Steps

By default, Squid Mesh does not reclaim a step that is already marked
`running`. A duplicate or redelivered job skips the running step instead of
starting another attempt.

Host applications can opt in with `execution[:stale_step_timeout]`, measured in
milliseconds. When enabled, a later redelivery can reclaim a `running` step whose
step-run row has not been updated within that timeout. Reclaim marks the
previous running attempt and step as failed with `reason: "stale_running_step"`,
then prepares the same step again.

Reclaim applies only while the run is still active. In practice the run is
`:running` for the step being recovered; a `:pending` or `:retrying` run is
transitioned back to `:running` during preparation. Terminal runs are skipped,
and cancelling runs converge through cancellation instead of reclaiming work.

Set this value higher than the longest normal step runtime. Squid Mesh does not
heartbeat long-running actions while they execute, so a timeout that is too low
can allow duplicate execution of a slow but still-running step. Steps that call
external systems should still use idempotency keys or another duplicate-safety
strategy.

## Long Waits

Built-in `:wait` steps are non-blocking because they reschedule continuation
through Oban instead of sleeping inside a worker.

Still, long waits have real operational cost:

- more scheduled jobs
- longer-lived run records
- more delayed work to reason about during incidents

Recommended practice:

- keep `:wait` for workflow-scale delays, not arbitrary timers everywhere
- prefer application scheduling or cron triggers when the delay is really about when the workflow should start
- avoid extremely large waits unless the workflow truly needs to remain in-flight

## Cron Activation

Cron triggers are declared in the workflow but activated by the host app
through `SquidMesh.Plugins.Cron`.

Current boundary:

- activation is static at boot
- Oban owns recurring scheduling
- Squid Mesh turns the cron tick into a normal `start_run/3` call

Recommended practice:

- treat cron workflows as deploy-time configuration
- review cron registrations alongside the host app's Oban setup
- keep payload defaults complete so cron runs do not rely on manual input

## Observability

At minimum, production deployments should capture:

- run lifecycle telemetry
- step lifecycle telemetry
- queue depth and throughput from Oban
- structured logs with run and step metadata

Recommended reading:

- [Observability](observability.md)
- [Architecture](architecture.md)
