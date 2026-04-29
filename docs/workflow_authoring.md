# Workflow Authoring

This guide covers the workflow contract that Squid Mesh supports today.

## Define A Workflow

Workflows are Elixir modules that `use SquidMesh.Workflow` and declare:

- one trigger
- one payload contract
- one or more steps
- either transitions between steps or dependency-based `after: [...]` joins
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
```

Built-in step options supported today:

- `:wait` requires `duration`
- `:log` requires `message` and accepts `level`
- `:wait` uses Oban-delayed continuation so long waits do not block a worker slot

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

## Dependency-Based Steps

Steps can also wait on explicit dependencies instead of success transitions:

```elixir
step(:load_account, Billing.Steps.LoadAccount)
step(:load_invoice, Billing.Steps.LoadInvoice)
step(:prepare_notification, Billing.Steps.PrepareNotification,
  after: [:load_account, :load_invoice]
)
```

Current dependency validation requires:

- every `after:` reference names a declared step
- the dependency graph is acyclic
- workflows may define multiple entry steps when dependency execution is used
- dependency-based workflows do not also declare `transition/2`

Current execution boundary:

- a step becomes runnable only after every dependency has completed successfully
- multiple ready root steps are executed in deterministic workflow declaration order today
- Squid Mesh does not yet dispatch multiple ready steps in parallel

## Transitions

Transitions define the path through the workflow.

```elixir
transition(:check_gateway_status, on: :ok, to: :notify_customer)
transition(:notify_customer, on: :ok, to: :complete)
```

Current workflow validation requires:

- at least one step
- exactly one trigger
- exactly one workflow entry step for transition-based workflows
- transitions that reference known steps

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
step attempt.

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
- sequential transitions
- dependency-based joins with `after: [...]`
- durable retries and replay
- built-in `:wait` and `:log` steps

Not implemented today:

- parallel dispatch of multiple ready steps
- conditional branching beyond transition outcomes
- dynamic cron registration after boot
- custom reclaim logic for interrupted in-flight step ownership
