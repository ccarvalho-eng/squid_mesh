# 0003 - Recovery boundary

## Status

Accepted

## Context

Durable workflow claims need to be accurate. Squid Mesh should be explicit
about what it guarantees and where it relies on Oban and idempotent step
implementations.

## Decision

Squid Mesh does not implement a custom heartbeat or lease system in V1.

Instead, V1 relies on:

- Oban for durable delivery, retries, and delayed scheduling
- persisted run, step, and attempt state in Postgres
- stale-delivery and duplicate-delivery guards at the workflow layer
- idempotent step implementations for external side effects

## Consequences

- V1 remains operationally simpler and avoids re-implementing worker coordination
- recovery guarantees are strong for queued and scheduled work
- interrupted in-flight side effects are not automatically reclaimed by custom ownership logic
- documentation must be explicit about this boundary
