# Workflow Authoring

This guide covers the workflow contract that Squid Mesh supports today.

## Define A Workflow

Workflows are Elixir modules that `use SquidMesh.Workflow` and declare:

- one trigger
- one payload contract
- one or more steps
- transitions between steps
- optional dependency-based `after: [...]` joins on steps that wait for other work
- optional retry policy on the steps that own side effects

```elixir
defmodule Billing.Workflows.PaymentRecovery do
  use SquidMesh.Workflow

  workflow do
    trigger :payment_recovery do
      manual()

      payload do
        field(:account_id, :string)
        field(:invoice_id, :string)
        field(:attempt_id, :string)
        field(:gateway_url, :string)
      end
    end

    step(:load_invoice, Billing.Steps.LoadInvoice)
    step(:wait_for_settlement, :wait, duration: 5_000)
    step(:log_recovery_attempt, :log,
      message: "Invoice loaded, checking gateway status",
      level: :info
    )
    step(:check_gateway_status, Billing.Steps.CheckGatewayStatus,
      retry: [max_attempts: 5, backoff: [type: :exponential, min: 1_000, max: 30_000]]
    )
    step(:notify_customer, Billing.Steps.NotifyCustomer)

    transition(:load_invoice, on: :ok, to: :wait_for_settlement)
    transition(:wait_for_settlement, on: :ok, to: :log_recovery_attempt)
    transition(:log_recovery_attempt, on: :ok, to: :check_gateway_status)
    transition(:check_gateway_status, on: :ok, to: :notify_customer)
    transition(:notify_customer, on: :ok, to: :complete)
  end
end
```

## Triggers

Triggers define how a workflow run starts.

Supported trigger types:

- `manual()`
- `cron(expression, timezone: "Etc/UTC")`

Trigger names are business-oriented entrypoints such as `:payment_recovery` or
`:invoice_delivery`. The trigger type describes how that entrypoint is invoked.

Current boundary:

- trigger metadata is validated and stored in the workflow definition
- manual triggers are runnable through the public API
- cron triggers are activated by opting workflows into `SquidMesh.Plugins.Cron`

Cron workflow example:

```elixir
defmodule Content.Workflows.PostDailyDigest do
  use SquidMesh.Workflow

  workflow do
    trigger :daily_digest do
      cron("0 9 * * 1-5", timezone: "Etc/UTC")

      payload do
        field(:feed_url, :string, default: "https://example.com/feed.xml")
        field(:discord_webhook_url, :string)
        field(:posted_on, :string, default: {:today, :iso8601})
      end
    end

    step(:fetch_feed, Content.Steps.FetchFeed)
    step(:build_digest, Content.Steps.BuildDigest)
    step(:post_to_discord, Content.Steps.PostToDiscord,
      retry: [max_attempts: 5, backoff: [type: :exponential, min: 1_000, max: 30_000]]
    )

    transition(:fetch_feed, on: :ok, to: :build_digest)
    transition(:build_digest, on: :ok, to: :post_to_discord)
    transition(:post_to_discord, on: :ok, to: :complete)
  end
end
```

Host-app opt-in example:

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  plugins: [
    {SquidMesh.Plugins.Cron,
     workflows: [
       MyApp.Workflows.DailyStandup
     ]}
  ],
  queues: [squid_mesh: 10]
```

Current cron boundary:

- Squid Mesh declares cron intent in the workflow DSL
- Oban performs the actual recurring scheduling
- cron workflow registration is static at boot today

## Payload

The trigger `payload` block defines the run input contract.

```elixir
payload do
  field(:account_id, :string)
  field(:invoice_id, :string)
  field(:prompt_date, :string, default: {:today, :iso8601})
end
```

Supported field types today:

- `:string`
- `:integer`
- `:float`
- `:boolean`
- `:map`
- `:list`
- `:atom`

Supported defaults today:

- literal values that match the declared field type
- `{:today, :iso8601}` for ISO-8601 dates generated at run creation time

Payload validation runs before the run is persisted.

## Steps

Each `step` is either:

- a module that performs domain work
- a built-in primitive supplied by the runtime

Module step:

```elixir
step(:load_invoice, Billing.Steps.LoadInvoice)
```

Built-in steps:

```elixir
step(:wait_for_settlement, :wait, duration: 5_000)
step(:log_recovery_attempt, :log, message: "Checking gateway status", level: :info)
step(:wait_for_approval, :pause)
approval_step(:wait_for_review, output: :approval)
```

Built-in step options supported today:

- `:wait` requires `duration`
- `:log` requires `message` and accepts `level`
- `:pause` intentionally stops the run at that step until an operator resumes it
- `approval_step/2` pauses the run for an explicit approve/reject decision and uses `:ok` or `:error` transitions to continue
- `:wait` uses Oban-delayed continuation so long waits do not block a worker slot
- `:pause` is supported in transition-based workflows; dependency-based workflows cannot declare `:pause`
- `approval_step/2` is also transition-based only; dependency-based workflows cannot declare built-in `:approval` steps

Manual approval example:

```elixir
approval_step(:wait_for_approval, output: :approval)
step(:record_approval, Billing.Steps.RecordApproval,
  input: [:account_id, :approval],
  output: :approval
)

step(:record_rejection, Billing.Steps.RecordRejection,
  input: [:account_id, :approval],
  output: :approval
)

transition(:wait_for_approval, on: :ok, to: :record_approval)
transition(:wait_for_approval, on: :error, to: :record_rejection)
transition(:record_approval, on: :ok, to: :complete)
transition(:record_rejection, on: :ok, to: :complete)
```

When a run is paused at an approval step, inspect it as usual and then approve
or reject it through the public API:

```elixir
{:ok, paused_run} = SquidMesh.inspect_run(run_id, include_history: true)
{:ok, approved_run} = SquidMesh.approve_run(run_id, %{actor: "ops_123"})
{:ok, rejected_run} = SquidMesh.reject_run(run_id, %{actor: "ops_456"})
```

With `include_history: true`, the inspected run also exposes `audit_events` so
host apps can show who paused, resumed, approved, or rejected the run and when:

```elixir
Enum.map(paused_run.audit_events, &{&1.type, &1.step})
#=> [{:paused, :wait_for_approval}]
```

Manual-review durability notes:

- `approval_step/2` is only supported in transition-based workflows
- the approval step stays `:running` while the run is `:paused`
- `approve_run/3` completes that step and advances the declared `:ok` path
- `reject_run/3` completes that step and advances the declared `:error` path
- reviewer identity, decision, timestamp, and optional review metadata are persisted in the completed step output and merged run context
- `inspect_run(..., include_history: true)` also returns durable audit events for pause, resume, approval, and rejection actions
- the resolved `:ok` and `:error` targets plus output-mapping metadata are persisted with the paused step so restart or deploy boundaries do not recompute review semantics from the current workflow definition
- host apps should apply the latest Squid Mesh migrations before using pause-resume in existing environments

## Step Modules

Custom steps typically use `Jido.Action` and return workflow output in a plain
map.

```elixir
defmodule Billing.Steps.CheckGatewayStatus do
  use Jido.Action,
    name: "check_gateway_status",
    description: "Checks gateway state",
    schema: [
      invoice: [type: :map, required: true],
      gateway_url: [type: :string, required: true]
    ]

  @impl true
  def run(%{invoice: invoice, gateway_url: gateway_url}, _context) do
    case SquidMesh.Tools.invoke(SquidMesh.Tools.HTTP, %{method: :get, url: gateway_url}) do
      {:ok, result} ->
        {:ok, %{gateway_check: %{invoice_id: invoice.id, status: result.payload.body}}}

      {:error, error} ->
        {:error, SquidMesh.Tools.Error.to_map(error)}
    end
  end
end
```

Step result contract:

- success: `{:ok, map()}`
- failure: `{:error, map()}`

## Data Flow Between Steps

Each run starts with its validated payload.

When a step succeeds:

- Squid Mesh merges the returned map into the run context
- the next step receives the original payload merged with the accumulated context

That means later steps can use values produced by earlier steps without manual
state persistence in the host application.

If you want a step to consume only a subset of the available data, declare an
explicit input mapping:

```elixir
step(:load_account, Billing.Steps.LoadAccount, input: [:account_id], output: :account)
step(:send_email, Billing.Steps.SendEmail, input: [:account, :invoice_id], output: :delivery)
```

In that example:

- `:load_account` receives only `%{account_id: ...}`
- its returned map is stored under `:account`
- `:send_email` receives only `%{account: ..., invoice_id: ...}`
- its returned map is stored under `:delivery`

Current boundary:

- run context is still a flat merged map
- explicit `input: [...]` lets a step declare which keys it consumes
- explicit `output: :key` lets a step namespace its returned map under one top-level key
- dependency-based workflows with parallel branches should still emit disjoint top-level keys unless they intentionally namespace outputs
- if multiple parallel branches write the same key, the result is not a stable workflow contract today

## Dependency-Based Steps

Steps can also wait on explicit dependencies instead of success transitions:

```elixir
step(:load_account, Billing.Steps.LoadAccount)
step(:load_invoice, Billing.Steps.LoadInvoice)
step(:prepare_notification, Billing.Steps.PrepareNotification,
  after: [:load_account, :load_invoice]
)
```

Choose dependency-based steps when you want to model prerequisites and joins.
They can still express a sequential chain such as `step_2 after: [:step_1]` and
`step_3 after: [:step_2]`, but if the workflow is only a straight ordered path,
`transition/2` is usually the clearer fit because it states the next step
directly.

Use `transition/2` when the workflow is a single ordered path and each step
chooses the next step by outcome. Use `after: [...]` when a step should wait
for one or more prerequisite steps, especially when multiple root steps fan in
to a join step.

If the workflow is just a straight line, prefer `transition/2` because it makes
the step-to-step path explicit. Use `after: [...]` when you want to model the
workflow as a dependency graph, including joins or a mix of independent roots
and later dependent steps.

In the example above, `:load_account` and `:load_invoice` are independent root
steps. Squid Mesh does not need a transition between them because neither one
depends on the other. They may be enqueued independently, and
`:prepare_notification` becomes runnable only after both have completed.

`after: [...]` makes a step runnable only after every named dependency
completes successfully. Omit the option entirely for root steps; `after: []` is
not valid because it changes execution semantics without adding a dependency
edge. Dependency workflows do not mix with `transition/2` in this slice.

Current dependency validation requires:

- every `after:` reference names a declared step
- the dependency graph is acyclic
- workflows may define multiple entry steps when dependency execution is used
- `after: []` is rejected because it changes execution semantics without adding an edge
- dependency-based workflows cannot also declare `transition/2`

Current execution boundary:

- a step becomes runnable only after every dependency has completed successfully
- multiple ready root steps can be enqueued independently while later phases still respect deterministic dependency order
- the current scheduler resolves dependency readiness from persisted step history after each successful dependency step, so it is intended for small and medium graph workflows
- downstream work is only enqueued from a locked run-progression boundary, so a sibling terminal failure prevents later dispatch

## Transitions

Transitions define the path through the workflow.

```elixir
transition(:check_gateway_status, on: :ok, to: :notify_customer)
transition(:check_gateway_status, on: :error, to: :notify_operator)
transition(:notify_customer, on: :ok, to: :complete)
```

Current workflow validation requires:

- at least one step
- exactly one trigger
- exactly one workflow entry step for transition-based workflows
- dependency-based workflows expose `entry_steps` plus `initial_step`; the singular `entry_step` is `nil`
- transitions only use supported outcomes: `:ok` and `:error`
- transitions reference known steps
- each `{from, on}` pair is declared at most once

## Retries And Backoff

Retry policy lives on the step that owns the work:

```elixir
step(:check_gateway_status, Billing.Steps.CheckGatewayStatus,
  retry: [max_attempts: 5, backoff: [type: :exponential, min: 1_000, max: 30_000]]
)
```

Supported retry options today:

- `max_attempts`
- `backoff: [type: :exponential, min: ..., max: ...]`

Squid Mesh resolves workflow retry policy and uses Oban to schedule the next
step attempt. If a step also declares an `on: :error` transition, Squid Mesh
takes that route only after retries are exhausted.

## Starting Runs

If a workflow defines a single trigger, the short path is:

```elixir
SquidMesh.start_run(Billing.Workflows.PaymentRecovery, %{
  account_id: account_id,
  invoice_id: invoice_id,
  attempt_id: attempt_id,
  gateway_url: gateway_url
})
```

If you want to name the trigger explicitly:

```elixir
SquidMesh.start_run(Billing.Workflows.PaymentRecovery, :payment_recovery, %{
  account_id: account_id,
  invoice_id: invoice_id,
  attempt_id: attempt_id,
  gateway_url: gateway_url
})
```

## Current Boundaries

The current workflow contract is intentionally smaller than a full graph engine.

Supported today:

- one trigger per workflow
- sequential transitions with explicit `:ok` and `:error` outcomes
- dependency-based joins with `after: [...]`
- durable retries and replay
- built-in `:wait`, `:log`, `:pause`, and `:approval` steps

Not implemented today:

- parallel dispatch of multiple ready steps
- conditional branching beyond transition outcomes
- dynamic cron registration after boot
- custom reclaim logic for interrupted in-flight step ownership
