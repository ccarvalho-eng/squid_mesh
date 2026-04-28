# 0001 - Runtime boundaries

## Status

Accepted

## Context

Squid Mesh needs to provide durable workflow semantics without becoming a
standalone platform or re-implementing lower-level background execution
infrastructure.

## Decision

Squid Mesh owns:

- declarative workflow structure
- payload validation
- run state, step state, and attempt history
- transitions, retries, replay, cancellation, and inspection

Squid Mesh delegates:

- durable job execution and delayed scheduling to Oban
- step behavior execution to Jido
- durable state storage to Postgres through the host application's repo

## Consequences

- the public API stays focused on workflow concepts rather than job internals
- host applications reuse existing `Repo` and `Oban` infrastructure
- Squid Mesh does not need to become a separate service
- some runtime guarantees depend on step-level idempotency at external boundaries
