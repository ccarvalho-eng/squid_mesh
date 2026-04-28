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

  test "fails when no steps are declared" do
    assert_compile_error(
      """
      defmodule WorkflowWithoutSteps do
        use SquidMesh.Workflow

        workflow do
          input do
            field(:account_id, :string)
          end
        end
      end
      """,
      "at least one step is required"
    )
  end

  test "fails when step names are duplicated" do
    assert_compile_error(
      """
      defmodule WorkflowWithDuplicateSteps do
        use SquidMesh.Workflow

        workflow do
          step(:send_email, WorkflowWithDuplicateSteps.SendEmail)
          step(:send_email, WorkflowWithDuplicateSteps.RecordDelivery)
        end
      end
      """,
      "duplicate step names: :send_email"
    )
  end

  test "fails when retry policy is malformed" do
    assert_compile_error(
      """
      defmodule WorkflowWithInvalidRetry do
        use SquidMesh.Workflow

        workflow do
          step(:send_email, WorkflowWithInvalidRetry.SendEmail)
          retry(:send_email, max_attempts: 0)
        end
      end
      """,
      "retry for :send_email must define a positive :max_attempts"
    )
  end

  test "fails when retry references an unknown step" do
    assert_compile_error(
      """
      defmodule WorkflowWithUnknownRetryStep do
        use SquidMesh.Workflow

        workflow do
          step(:send_email, WorkflowWithUnknownRetryStep.SendEmail)
          retry(:record_delivery, max_attempts: 3)
        end
      end
      """,
      "retry references unknown step: :record_delivery"
    )
  end

  defp assert_compile_error(source, message) do
    error =
      assert_raise CompileError, fn ->
        Code.compile_string(source, "test/support/invalid_workflow.exs")
      end

    assert Exception.message(error) |> String.contains?(message)
  end
end
