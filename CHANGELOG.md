# Changelog

All notable changes to Squid Mesh will be documented in this file.

The format is based on Keep a Changelog and the project follows Semantic
Versioning, including prerelease tags while the runtime remains in early
development.

## [0.1.0-alpha.4] - 2026-05-10

### Added
- Run explanation diagnostics through `SquidMesh.explain_run/2`, including
  current reason, valid next actions, and supporting evidence for host app
  dashboards or CLIs.
- Multiple workflow triggers per workflow, with any mix of manual and cron
  entrypoints and per-trigger payload validation.
- Minimal host app documentation and smoke coverage for a workflow that can be
  started manually or by cron.

### Changed
- `mix squid_mesh.install` now installs one fresh current-schema Squid Mesh
  migration instead of copying the historical split migration set.

### Fixed
- Public run APIs now return structured `:invalid_run_id` errors for malformed
  run IDs.

### Notes
- This release intentionally does not provide a compatibility path for older
  split Squid Mesh migrations. Existing evaluation apps should reinstall from
  the current schema while the project remains in alpha.

## [0.1.0-alpha.3] - 2026-05-07

### Added
- Human-in-the-loop workflow support with paused runs and
  `SquidMesh.unblock_run/2`.
- Approval workflow primitives with `approval_step/2`,
  `SquidMesh.approve_run/3`, and `SquidMesh.reject_run/3`.
- Manual audit history for pause, resume, approval, and rejection actions when
  inspecting runs with `include_history: true`.
- Operations documentation for idempotent side-effect design and stale running
  step recovery.

### Changed
- Paused and approval runs now persist their resume targets and output mapping,
  so existing paused runs keep the same resume behavior across restarts and
  deploys.
- Runtime recovery paths now preserve queued step state more carefully during
  duplicate delivery, cancellation, retry, and dispatch-failure scenarios.
- Stale running step reclaim is opt-in. By default, a duplicate or redelivered
  job skips an already running step instead of starting another attempt after a
  timeout.
- README and guide language now focuses on setup, runtime behavior, and
  operational boundaries.

### Fixed
- Invalid `execution:` configuration now returns structured config errors
  instead of raising during config load.
- Runtime telemetry is emitted after the related durable state commits in
  progression paths that update run or step state.

### Notes
- This remains an alpha release. Steps that call external systems should use
  application-owned idempotency keys or another duplicate-safety strategy.

## [0.1.0-alpha.2] - 2026-05-04

### Added
- Dependency-based workflow steps with `after: [...]`, including durable
  scheduling of ready steps and dependency-aware host app examples.
- Explicit error routing for transition workflows with `transition(..., on:
  :error, to: ...)` after retries are exhausted.
- Explicit step `input: [...]` selection and `output: :key` namespacing for
  clearer data flow between workflow steps.
- Graph-aware inspection with a public `steps` view alongside chronological
  `step_runs` when `inspect_run(..., include_history: true)` is enabled.

### Changed
- Refactored runtime execution into clearer prepare, execute, and apply phases
  without changing the public workflow DSL.
- Hardened dependency-mode concurrency, step claiming, retry progression, and
  terminal-run dispatch behavior across parallel branch execution.
- Expanded host app smoke and integration coverage to exercise dependency
  workflows, mapped step I/O, and nonlinear inspection paths end to end.

### Notes
- This is still an alpha release. The runtime is stronger for evaluation and
  internal integration work, but the production-readiness bar remains unchanged.

## [0.1.0-alpha.1] - 2026-04-28

### Added
- Declarative workflow DSL with manual and cron triggers, payload contracts,
  built-in steps, transitions, and step-level retry/backoff configuration.
- Durable runtime built on Postgres and Oban, including replay, cancellation,
  cron activation, run inspection, and step/attempt history.
- Tool adapter boundary with an HTTP adapter and runtime observability hooks.
- Example host app with smoke, resilience, and bounded soak verification paths.
- Compatibility, operations, and production-readiness documentation.

### Changed
- Clarified the runtime boundary between Squid Mesh, Oban, Jido, and host
  applications across the README and docs.
- Disabled Jido's internal action retries at the Squid Mesh boundary so one
  workflow attempt maps to one persisted step attempt.

### Notes
- This is an alpha release. The runtime is suitable for evaluation, local
  development, and internal integration work, but it is not yet positioned as
  production-ready.
