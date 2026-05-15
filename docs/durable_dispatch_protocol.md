# Durable Dispatch Protocol

Squid Mesh's new runtime path treats dispatch state as an append-only journal.
The protocol and pure projection are storage-independent, and
`SquidMesh.Runtime.Journal` persists the same entries through `Jido.Storage`
thread journals and checkpoints.

## Threads

- Run thread: workflow lifecycle facts such as run start, planned runnables,
  applied runnable results, and terminal status.
- Dispatch thread: runnable intent, claim, heartbeat, completion, failure, retry
  visibility, and live wakeup facts.
- Run index thread: rebuildable lookup entries for finding runs by workflow or
  host-facing keys.

`SquidMesh.Runtime.Journal` maps those logical threads to Jido thread IDs such
as `squid_mesh:run:<run-id>`, `squid_mesh:dispatch:<queue>`, and
`squid_mesh:run_index:<workflow>`. Runtime entries keep the Squid Mesh protocol
type as the Jido entry kind and store the protocol data as the entry payload, so
projections can be rebuilt from the thread after process restart.

## Jido.Storage Boundary

The journal boundary accepts any configured `Jido.Storage` adapter. It appends
entries with Jido's optimistic `:expected_rev` option, returns `{:error,
:conflict}` for stale appends, and stores projection checkpoints with the exact
Jido thread revision they cover. Checkpoints are rebuild accelerators; the
append-only thread remains the source of truth.

This first storage-backed slice proves the Squid Mesh protocol can persist and
restore dispatch projections through `Jido.Storage`. The live runtime still uses
the current host-executor and Postgres table path until the Jido-native workflow
and dispatch agents land.

For production adapters, the required storage properties are:

- ordered thread append with stable per-thread sequence numbers
- optimistic append conflict detection through `:expected_rev`
- checkpoint overwrite semantics for compact projections
- durable reload of thread entries and checkpoints after process restart

The Postgres path should use a `jido_ecto` adapter when that adapter provides
those properties. The Bedrock path should use a `jido_bedrock` adapter where
Bedrock is available. Squid Mesh should not introduce a second persistence
contract for those stores; adapters only need to satisfy `Jido.Storage`.

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

`SquidMesh.Runtime.DispatchAgent.claim_next/4`,
`SquidMesh.Runtime.DispatchAgent.heartbeat/6`,
`SquidMesh.Runtime.DispatchAgent.complete/7`, and
`SquidMesh.Runtime.DispatchAgent.fail/7` are the current durable claim lifecycle
boundaries for the Jido-native runtime work. Claiming selects the next visible
or expired attempt from a rebuilt dispatch-agent projection and appends an
`attempt_claimed` entry with Jido's optimistic `:expected_rev` fence. Heartbeat,
completion, and failure appends validate the current claim fence before writing,
then append the matching lifecycle entry with the same optimistic thread fence.
On success, each API returns the post-append dispatch-agent projection;
concurrent stale callers receive `{:error, :conflict}` from the journal append.

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
