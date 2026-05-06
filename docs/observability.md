# Observability

Squid Mesh emits baseline telemetry and structured logs around run and step
lifecycle events.

## Telemetry Events

All events are emitted under the `[:squid_mesh, ...]` prefix.

Run lifecycle:

- `[:squid_mesh, :run, :created]`
- `[:squid_mesh, :run, :replayed]`
- `[:squid_mesh, :run, :dispatched]`
- `[:squid_mesh, :run, :transition]`

Step lifecycle:

- `[:squid_mesh, :step, :started]`
- `[:squid_mesh, :step, :skipped]`
- `[:squid_mesh, :step, :completed]`
- `[:squid_mesh, :step, :failed]`
- `[:squid_mesh, :step, :retry_scheduled]`

## Common Metadata

Run events include:

- `run_id`
- `workflow`
- `trigger`
- `status`
- `current_step`

Run dispatch events also include:

- `job_id`
- `queue`
- `schedule_in`

Run transition events also include:

- `from_status`
- `to_status`

Step events include:

- `run_id`
- `workflow`
- `trigger`
- `status`
- `current_step`
- `step`
- `attempt`

Step failure events also include:

- `error`

Step skip events also include:

- `reason`

## Measurements

All events include `system_time`.

Additional measurements:

- step completion and failure events include `duration`
- retry scheduling events include `delay_ms`

`duration` is emitted in native time units.

For ordinary step execution, duration is measured from `System.monotonic_time/0`
within the executing worker. For paused-step completion or failure, the terminal
event can happen later during unblock or cancellation, so duration is derived
from the persisted attempt start timestamp instead.

That means a paused manual step such as `:pause` or `approval_step/2` emits:

- `step.started` when the pause step is first executed
- `step.completed` later during `unblock_run/2`, `approve_run/3`, or `reject_run/3`, or `step.failed` if the paused run is cancelled

The terminal event still refers to the original running attempt, but its
duration spans the full paused interval rather than only the worker execution
window.

## Structured Logs

Squid Mesh sets logger metadata for step execution so failure logs carry:

- `run_id`
- `workflow`
- `step`
- `attempt`

This metadata is attached in the step execution path so host applications can
route or format logs with run-oriented context without parsing message strings.
