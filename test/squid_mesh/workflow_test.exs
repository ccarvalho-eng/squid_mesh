defmodule SquidMesh.WorkflowTest do
  use ExUnit.Case

  defmodule InvoiceReminder do
    use SquidMesh.Workflow

    workflow do
      input do
        field(:account_id, :string)
        field(:invoice_id, :string)
      end

      step(:load_invoice, InvoiceReminder.LoadInvoice)
      step(:send_email, InvoiceReminder.SendEmail)
      step(:record_delivery, InvoiceReminder.RecordDelivery)

      transition(:load_invoice, on: :ok, to: :send_email)
      transition(:send_email, on: :ok, to: :record_delivery)
      transition(:record_delivery, on: :ok, to: :complete)

      retry(:send_email, max_attempts: 3)
    end
  end

  test "exposes a declarative workflow definition" do
    definition = InvoiceReminder.workflow_definition()

    assert definition.input == [
             %{name: :account_id, type: :string, opts: []},
             %{name: :invoice_id, type: :string, opts: []}
           ]

    assert definition.steps == [
             %{name: :load_invoice, module: InvoiceReminder.LoadInvoice, opts: []},
             %{name: :send_email, module: InvoiceReminder.SendEmail, opts: []},
             %{name: :record_delivery, module: InvoiceReminder.RecordDelivery, opts: []}
           ]

    assert definition.transitions == [
             %{from: :load_invoice, on: :ok, to: :send_email},
             %{from: :send_email, on: :ok, to: :record_delivery},
             %{from: :record_delivery, on: :ok, to: :complete}
           ]

    assert definition.retries == [
             %{step: :send_email, opts: [max_attempts: 3]}
           ]
  end

  test "exposes the workflow contract shape" do
    assert InvoiceReminder.__workflow__(:contract) == %{
             required: [:step],
             optional: [:input, :transition, :retry]
           }
  end

  test "supports introspection of definition segments" do
    assert InvoiceReminder.__workflow__(:steps) == InvoiceReminder.workflow_definition().steps
    assert InvoiceReminder.__workflow__(:input) == InvoiceReminder.workflow_definition().input

    assert InvoiceReminder.__workflow__(:transitions) ==
             InvoiceReminder.workflow_definition().transitions

    assert InvoiceReminder.__workflow__(:retries) == InvoiceReminder.workflow_definition().retries
  end
end
