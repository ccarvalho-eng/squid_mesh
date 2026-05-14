# Durable Dispatch Protocol

Squid Mesh's new runtime path treats dispatch state as an append-only journal.
This slice defines the protocol and pure projection first. A later storage slice
can persist the same entries through Jido thread journals, one Squid Mesh-owned
journal table, or an IntentLedger-backed adapter.

## Threads

- Run thread: workflow lifecycle facts such as run start, planned runnables,
  applied runnable results, and terminal status.
- Dispatch thread: runnable intent, claim, heartbeat, completion, failure, retry
  visibility, and live wakeup facts.
- Run index thread: rebuildable lookup entries for finding runs by workflow or
  host-facing keys.

## Commit Order

Durable facts must be appended before live effects are treated as successful. A
worker wakeup is recoverable only when a matching runnable intent already exists
in the dispatch journal. If a wakeup is lost after the intent append, the
projection can still rediscover the visible attempt after restart. Duplicate
runnable intent entries are idempotent when their scheduled fields match;
conflicting entries for the same `runnable_key` are anomalies.

For dependency-based workflows, Runic-ready runnables map to durable runnable
intent. Independent root steps may produce sibling runnable intents for the same
run, and a join step produces intent only after every dependency result has
already become durable. The dispatch protocol does not use host-job concurrency
as the source of truth for fan-out or fan-in readiness; persisted workflow facts
do.

## IntentLedger Alignment

Squid Mesh models workflow-specific facts, but its dispatch vocabulary is
compatible with IntentLedger's durable intent model:

- `attempt_scheduled` maps to a visible intent.
- `runnable_key` is the Squid workflow identity for an intent.
- `step` and `input` map to intent kind and payload.
- `claim_id`, `claim_token_hash`, `owner_id`, and `lease_until` mirror
  IntentLedger claim fencing and lease state.
- `attempt_heartbeat`, `attempt_completed`, and `attempt_failed` require the
  current claim fence.

Squid Mesh should integrate through a dispatch backend adapter rather than make
IntentLedger depend on Squid-specific workflow concepts. The adapter can map
Squid runnables to IntentLedger intents and translate lifecycle signals back
into the projection.

## Job Runner Boundary

The protocol does not assume Oban, Broadway, IntentLedger, or a custom process as
the delivery mechanism. A runner may wake, claim, execute, retry, or redeliver
work, but Squid Mesh treats the journal as authoritative for intent, claim,
lease, fencing, completion, failure, and retry visibility.

## Claims, Leases, And Heartbeats

Each attempt is fenced by `claim_id` and `claim_token_hash`. Workers hold the raw
claim token, but durable entries record only its hash. A heartbeat extends
`lease_until` only when it carries the current claim fence. Heartbeats from stale
claims are ignored by the projection and surfaced as anomalies. Expired claims
remain discoverable so a dispatch agent can redeliver work without relying on
in-memory state. A replacement claim is valid only after the prior lease has
expired; active claim takeover is an anomaly. Claims are valid only after the
attempt's `visible_at`, and heartbeat, completion, and failure facts are valid
only before the current lease expires.

IntentLedger is the intended future integration point for heartbeat execution
and lease management once its durable Ecto/Postgres path is stable. Until then,
Squid Mesh keeps the protocol dependency-free.

## Completion And Retry

Completion and failure entries must also carry the current claim fence.
Duplicate completion entries with the same claim and result are idempotent.
Conflicting or stale completions are ignored and reported as anomalies. Retry
scheduling is a durable fact with its own `visible_at`, so retry visibility
survives restart. A runnable result can be applied to the run thread only after
the matching completion is durable.

## Terminal Runs

A `run_terminal` entry fences remaining dispatch work for the run. Rebuilt
projections exclude terminal-run attempts from visible and expired-claim
redelivery views, and later wakeup, claim, completion, failure, or apply entries
for that run are surfaced as anomalies.
