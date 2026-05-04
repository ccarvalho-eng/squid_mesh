defmodule MinimalHostApp.WorkflowRunsTest do
  use MinimalHostApp.DataCase

  alias MinimalHostApp.Smoke
  alias MinimalHostApp.WorkflowRuns

  test "starts the example payment recovery workflow through the host boundary" do
    bypass = Bypass.open()

    attrs = %{
      account_id: "acct_123",
      invoice_id: "inv_456",
      attempt_id: "attempt_789",
      gateway_url: endpoint_url(bypass.port, "/gateway")
    }

    assert {:ok, run} = WorkflowRuns.start_payment_recovery(attrs)

    assert_enqueued(
      worker: SquidMesh.Workers.StepWorker,
      queue: "squid_mesh",
      args: %{"run_id" => run.id, "step" => "load_invoice"}
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
               attempt_id: "attempt_789",
               gateway_url: "http://127.0.0.1:4010/gateway"
             })

    assert {:ok, inspected_run} = WorkflowRuns.inspect_payment_recovery(run.id)
    assert inspected_run == run
  end

  test "executes a dependency-based workflow through the host boundary" do
    attrs = %{
      account_id: "acct_123",
      invoice_id: "inv_456",
      attempt_id: "attempt_789"
    }

    assert {:ok, run} = WorkflowRuns.start_dependency_recovery(attrs)
    assert run.current_step == nil

    assert :ok = MinimalHostApp.RuntimeHarness.wait_for_execution()
    assert {:ok, completed_run} = MinimalHostApp.RuntimeHarness.await_terminal_run(run.id)

    assert completed_run.status == :completed
    assert completed_run.context.account == %{id: "acct_123", tier: "standard"}

    assert completed_run.context.invoice == %{
             id: "inv_456",
             account_id: "acct_123",
             attempt_id: "attempt_789"
           }

    assert completed_run.context.notification == %{
             channel: "email",
             account_id: "acct_123",
             invoice_id: "inv_456",
             account_tier: "standard"
           }
  end

  test "runs the documented smoke path" do
    assert %{payment_recovery: payment_recovery, dependency_recovery: dependency_recovery} =
             Smoke.run_all!()

    assert payment_recovery.status == :completed
    assert payment_recovery.context.notification.channel == "email"
    assert payment_recovery.context.gateway_check.status == "retry_required"

    assert dependency_recovery.status == :completed
    assert dependency_recovery.context.notification.channel == "email"
  end

  test "runs the cancellation smoke path" do
    assert %SquidMesh.Run{} = run = Smoke.run_cancellation!()
    assert run.status == :cancelled
  end

  defp endpoint_url(port, path) do
    "http://127.0.0.1:#{port}#{path}"
  end
end
