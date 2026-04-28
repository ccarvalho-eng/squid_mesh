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

`duration` is emitted in native time units from `System.monotonic_time/0`.

## Structured Logs

Squid Mesh sets logger metadata for step execution so failure logs carry:

- `run_id`
- `workflow`
- `step`
- `attempt`

This metadata is attached in the step execution path so host applications can
route or format logs with run-oriented context without parsing message strings.
