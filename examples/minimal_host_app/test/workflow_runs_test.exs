defmodule MinimalHostApp.WorkflowRunsTest do
  use MinimalHostApp.DataCase

  alias MinimalHostApp.Smoke
  alias MinimalHostApp.WorkflowRuns

  test "starts the example payment recovery workflow through the host boundary" do
    attrs = %{
      account_id: "acct_123",
      invoice_id: "inv_456",
      attempt_id: "attempt_789"
    }

    assert {:ok, run} = WorkflowRuns.start_payment_recovery(attrs)

    assert_enqueued(
      worker: SquidMesh.Workers.StepWorker,
      queue: "squid_mesh",
      args: %{"run_id" => run.id}
    )

    assert run.workflow == MinimalHostApp.Workflows.PaymentRecovery
    assert run.trigger == :payment_recovery
    assert run.status == :pending
    assert run.payload == attrs
    assert run.current_step == :load_invoice
  end

  test "inspects a started run through the host boundary" do
    assert {:ok, run} =
             WorkflowRuns.start_payment_recovery(%{
               account_id: "acct_123",
               invoice_id: "inv_456",
               attempt_id: "attempt_789"
             })

    assert {:ok, inspected_run} = WorkflowRuns.inspect_payment_recovery(run.id)
    assert inspected_run == run
  end

  test "runs the documented smoke path" do
    assert %SquidMesh.Run{} = run = Smoke.run!()
    assert run.status == :completed
    assert run.context.notification.channel == "email"
  end
end
