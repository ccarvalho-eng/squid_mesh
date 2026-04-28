# Architecture

Squid Mesh is a workflow automation platform for Elixir applications. It runs
inside a host application's supervision tree and infrastructure.

## Core Components

`SquidMesh.Workflow`

- declarative DSL for triggers, payload, steps, transitions, and retries

`SquidMesh`

- public runtime API for starting, inspecting, listing, cancelling, and replaying runs

`SquidMesh.RunStore`

- durable run persistence and run lifecycle transitions

`SquidMesh.StepRunStore`

- durable state for individual workflow steps

`SquidMesh.AttemptStore`

- persisted attempt history per step run

`SquidMesh.Runtime.Dispatcher`

- turns workflow execution intent into Oban jobs

`SquidMesh.Runtime.StepExecutor`

- executes one workflow step, merges step output into context, and advances the run

`SquidMesh.Runtime.RetryPolicy`

- resolves step-level retry policy into retry decisions and backoff delays

`SquidMesh.Tools`

- shared boundary for external adapters such as HTTP

## Runtime Responsibilities

Squid Mesh owns:

- workflow structure
- payload validation
- durable run state
- step state and attempt history
- replay and cancellation semantics
- retry policy at the workflow-step layer
- telemetry and structured log metadata

Oban owns:

- durable job execution
- queueing
- delayed scheduling
- redelivery after worker crashes or restarts

Jido owns:

- step behavior execution
- action contracts inside custom step modules

Postgres owns:

- source-of-truth persistence for runs, steps, and attempts

## Execution Flow

1. A host application starts a run through `SquidMesh.start_run/2`, `start_run/3`, or `start_run/4`.
2. Squid Mesh validates the workflow definition and payload.
3. Squid Mesh persists a pending run in Postgres.
4. The dispatcher enqueues one Oban job for the current workflow step.
5. The worker loads the run and executes the current step.
6. Step output is merged into run context.
7. The runtime decides whether the run completes, advances, retries, fails, or no-ops.
8. If more work is required, the dispatcher schedules the next step job through Oban.

## Recovery Boundary

Squid Mesh is intentionally not a replacement for Oban's worker coordination.

Current guarantees:

- run, step, and attempt history is durable
- queued and scheduled work survives deploys and restarts through Oban
- stale or duplicate deliveries are treated as workflow-level no-ops when possible

Current non-goals:

- custom heartbeats or leases beyond Oban's own lifecycle
- automatic reclamation of a step that died mid-side-effect
- exactly-once external side effects without idempotent step implementations

## Recommended Reading

- [Workflow authoring guide](workflow_authoring.md)
- [Host app integration](host_app_integration.md)
- [Tool adapters](tool_adapters.md)
- [Observability](observability.md)
- [ADR index](adr/index.md)
