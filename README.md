<div align="center">
  <img width="350" alt="image" src="https://github.com/user-attachments/assets/13d54dc4-e8f3-4183-84ab-b6bbe47f8081" />

  <p><i>Durable workflow runtime for Elixir applications.</i></p>

  [![CI](https://github.com/ccarvalho-eng/squid_mesh/actions/workflows/ci.yml/badge.svg)](https://github.com/ccarvalho-eng/squid_mesh/actions/workflows/ci.yml)
  [![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
</div>



Squid Mesh lets application teams define workflows declaratively in Elixir and execute them through a stable application-facing API. It is designed to plug into existing Phoenix and OTP applications so engineers can expose workflow capabilities through their own endpoints, services, and domain boundaries.

## What It Provides

- Declarative workflow definitions in Elixir modules
- Durable workflow runs and step state
- Retry, resume, cancel, and replay semantics
- Public API for starting, inspecting, listing, cancelling, and replaying runs
- Integration with an existing `Repo` and background job setup

## Product Shape

- Runs inside Elixir applications, not as a hosted product
- API-first runtime for Elixir applications
- Declarative developer experience that hides execution internals
- Built for operational visibility from day one

## Example Workflow

```elixir
defmodule Billing.Workflows.PaymentRecovery do
  use SquidMesh.Workflow

  workflow do
    input do
      field(:account_id, :string)
      field(:invoice_id, :string)
      field(:attempt_id, :string)
    end

    step(:load_invoice, Billing.Steps.LoadInvoice)
    step(:check_gateway, Billing.Steps.CheckGatewayStatus)
    step(:notify_customer, Billing.Steps.NotifyCustomer)
    step(:open_follow_up, Billing.Steps.OpenFollowUpTask)

    transition(:load_invoice, on: :ok, to: :check_gateway)
    transition(:check_gateway, on: :retry_required, to: :notify_customer)
    transition(:notify_customer, on: :ok, to: :open_follow_up)
    transition(:open_follow_up, on: :ok, to: :complete)

    retry(:check_gateway, max_attempts: 5)
  end
end
```

## Example Host App Call

```elixir
defmodule Billing do
  def recover_failed_payment(account_id, invoice_id, attempt_id) do
    SquidMesh.start_run(Billing.Workflows.PaymentRecovery, %{
      account_id: account_id,
      invoice_id: invoice_id,
      attempt_id: attempt_id
    })
  end
end
```

## Documentation

- [Host app integration](docs/host_app_integration.md)
- [Example host app harness](examples/minimal_host_app/README.md)
