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

- turns workflow execution intent into calls to the configured host executor

`SquidMesh.Executor`

- host-implemented behaviour for enqueueing step, compensation, and cron work

`SquidMesh.Runtime.Runner`

- backend-neutral entrypoint that host jobs call when queued work is delivered

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

The host executor owns:

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
4. The dispatcher asks the configured executor to enqueue the current workflow step.
5. The host job delivers the payload to `SquidMesh.Runtime.Runner.perform/1`.
6. Step output is merged into run context.
7. The runtime decides whether the run completes, advances, retries, fails, or no-ops.
8. If more work is required, the dispatcher asks the executor to enqueue the next step or delayed retry.

## Recovery Boundary

Squid Mesh is intentionally not a replacement for worker coordination in the
host job backend.

Current guarantees:

- run, step, and attempt history is durable
- queued and scheduled work can survive deploys and restarts when the host executor uses a durable backend
- stale or duplicate deliveries are treated as workflow-level no-ops when possible

Current non-goals:

- custom heartbeats or leases beyond the host backend's own lifecycle
- automatic reclamation of a step that died mid-side-effect
- exactly-once external side effects without idempotent step implementations

## Recommended Reading

- [Workflow authoring guide](workflow_authoring.md)
- [Host app integration](host_app_integration.md)
- [Tool adapters](tool_adapters.md)
- [Observability](observability.md)
