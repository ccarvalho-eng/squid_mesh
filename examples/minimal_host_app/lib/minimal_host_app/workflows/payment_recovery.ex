defmodule MinimalHostApp.Workflows.PaymentRecovery do
  @moduledoc """
  Example workflow used by the host app harness.
  """

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

    step(:load_invoice, MinimalHostApp.Steps.LoadInvoice)
    step(:check_gateway_status, MinimalHostApp.Steps.CheckGatewayStatus, retry: [max_attempts: 5])
    step(:notify_customer, MinimalHostApp.Steps.NotifyCustomer)

    transition(:load_invoice, on: :ok, to: :check_gateway_status)
    transition(:check_gateway_status, on: :ok, to: :notify_customer)
    transition(:notify_customer, on: :ok, to: :complete)
  end
end
