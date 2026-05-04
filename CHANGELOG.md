# Changelog

All notable changes to Squid Mesh will be documented in this file.

The format is based on Keep a Changelog and the project follows Semantic
Versioning, including prerelease tags while the runtime remains in early
development.

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
