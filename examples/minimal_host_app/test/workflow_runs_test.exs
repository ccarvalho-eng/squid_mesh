defmodule MinimalHostApp.WorkflowRunsTest do
  use ExUnit.Case

  alias MinimalHostApp.Smoke
  alias MinimalHostApp.TestSupport.FakeRepo
  alias MinimalHostApp.WorkflowRuns

  setup_all do
    start_supervised!(FakeRepo)
    :ok
  end

  setup do
    FakeRepo.reset()
    :ok
  end

  test "starts the example payment recovery workflow through the host boundary" do
    attrs = %{
      account_id: "acct_123",
      invoice_id: "inv_456",
      attempt_id: "attempt_789"
    }

    assert {:ok, run} = WorkflowRuns.start_payment_recovery(attrs)

    assert run.workflow == MinimalHostApp.Workflows.PaymentRecovery
    assert run.status == :pending
    assert run.input == attrs
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
    assert %SquidMesh.Run{} = Smoke.run!()
  end
end
