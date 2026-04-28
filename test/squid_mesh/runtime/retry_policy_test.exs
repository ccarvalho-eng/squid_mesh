defmodule SquidMesh.Runtime.RetryPolicyTest do
  use ExUnit.Case

  alias SquidMesh.Runtime.RetryPolicy

  defmodule InvoiceReminderWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:invoice_id, :string)
        end
      end

      step(:load_invoice, InvoiceReminderWorkflow.LoadInvoice)
      step(:send_email, InvoiceReminderWorkflow.SendEmail, retry: [max_attempts: 3])

      transition(:load_invoice, on: :ok, to: :send_email)
      transition(:send_email, on: :ok, to: :complete)
    end
  end

  defmodule NoRetryWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:notification_id, :string)
        end
      end

      step(:notify_customer, NoRetryWorkflow.NotifyCustomer)
      transition(:notify_customer, on: :ok, to: :complete)
    end
  end

  test "returns the configured max attempts for a retried step" do
    assert {:ok, 3} = RetryPolicy.max_attempts(InvoiceReminderWorkflow, :send_email)
  end

  test "returns no_retry when the step has no retry policy" do
    assert :no_retry = RetryPolicy.max_attempts(InvoiceReminderWorkflow, :load_invoice)
    assert :no_retry = RetryPolicy.max_attempts(NoRetryWorkflow, :notify_customer)
  end

  test "resolves the next attempt when retries remain" do
    assert {:retry, 2} = RetryPolicy.resolve(InvoiceReminderWorkflow, :send_email, 1)
    assert {:retry, 3} = RetryPolicy.resolve(InvoiceReminderWorkflow, :send_email, 2)
  end

  test "marks retry exhaustion when the policy is consumed" do
    assert {:exhausted, 3} = RetryPolicy.resolve(InvoiceReminderWorkflow, :send_email, 3)
    assert {:exhausted, 3} = RetryPolicy.resolve(InvoiceReminderWorkflow, :send_email, 4)
  end

  test "returns no_retry for steps without a configured policy" do
    assert :no_retry = RetryPolicy.resolve(InvoiceReminderWorkflow, :load_invoice, 1)
  end
end
