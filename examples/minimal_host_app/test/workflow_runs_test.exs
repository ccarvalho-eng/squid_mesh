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
    assert {:ok, history_run} = WorkflowRuns.inspect_run(run.id, include_history: true)

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

    assert Enum.map(history_run.steps, &{&1.step, &1.status, &1.depends_on}) == [
             {:load_account, :completed, []},
             {:load_invoice, :completed, []},
             {:prepare_notification, :completed, [:load_account, :load_invoice]}
           ]
  end

  test "approves a manual approval workflow through the host boundary" do
    assert {:ok, run} = WorkflowRuns.start_manual_approval(%{account_id: "acct_approval_123"})

    assert :ok = MinimalHostApp.RuntimeHarness.wait_for_execution()
    assert {:ok, paused_run} = WorkflowRuns.inspect_run(run.id, include_history: true)

    assert paused_run.status == :paused
    assert paused_run.current_step == :wait_for_approval

    assert Enum.map(paused_run.audit_events, &{&1.type, &1.step}) == [
             {:paused, :wait_for_approval}
           ]

    assert Enum.map(paused_run.steps, &{&1.step, &1.status}) == [
             {:wait_for_approval, :running},
             {:record_approval, :waiting},
             {:record_rejection, :waiting}
           ]

    assert {:ok, resumed_run} =
             WorkflowRuns.approve_run(
               run.id,
               %{actor: "ops_123", comment: "approved", metadata: %{ticket: "SUP-123"}}
             )

    assert resumed_run.status == :running
    assert resumed_run.current_step == :record_approval

    assert :ok = MinimalHostApp.RuntimeHarness.wait_for_execution()
    assert {:ok, completed_run} = MinimalHostApp.RuntimeHarness.await_terminal_run(run.id)
    assert {:ok, completed_history} = WorkflowRuns.inspect_run(run.id, include_history: true)

    assert completed_run.status == :completed

    assert completed_run.context.approval.account_id == "acct_approval_123"
    assert completed_run.context.approval.status == "approved"
    assert completed_run.context.approval.decision == "approved"
    assert completed_run.context.approval.actor == "ops_123"
    assert completed_run.context.approval.comment == "approved"

    assert Enum.map(completed_history.audit_events, &{&1.type, &1.step, &1.actor}) == [
             {:paused, :wait_for_approval, nil},
             {:approved, :wait_for_approval, "ops_123"}
           ]

    assert Enum.map(completed_history.audit_events, & &1.metadata) == [
             nil,
             %{ticket: "SUP-123"}
           ]
  end

  test "runs the daily digest workflow through its manual trigger" do
    attrs = %{channel: "ops-manual", digest_date: "2026-05-10"}

    assert {:ok, run} = WorkflowRuns.start_manual_digest(attrs)

    assert run.workflow == MinimalHostApp.Workflows.DailyDigest
    assert run.trigger == :manual_digest
    assert run.payload == attrs

    assert_enqueued(
      worker: SquidMesh.Workers.StepWorker,
      queue: "squid_mesh",
      args: %{"run_id" => run.id, "step" => "announce_digest"}
    )

    assert :ok = MinimalHostApp.RuntimeHarness.wait_for_execution()
    assert {:ok, completed_run} = MinimalHostApp.RuntimeHarness.await_terminal_run(run.id)

    assert completed_run.status == :completed
    assert completed_run.context.digest_delivery.channel == "ops-manual"
    assert completed_run.context.digest_delivery.digest_date == "2026-05-10"

    assert {:ok, inspected_run} = WorkflowRuns.inspect_run(run.id)
    assert inspected_run.payload == attrs
  end

  test "runs the daily digest workflow through its cron trigger" do
    existing_run_ids =
      case WorkflowRuns.list_daily_digest_runs() do
        {:ok, runs} -> MapSet.new(runs, & &1.id)
        {:error, _reason} -> MapSet.new()
      end

    job = %Oban.Job{
      args: %{
        "workflow" => "Elixir.MinimalHostApp.Workflows.DailyDigest",
        "trigger" => "daily_digest"
      }
    }

    assert :ok = SquidMesh.Workers.CronTriggerWorker.perform(job)

    assert_enqueued(
      worker: SquidMesh.Workers.StepWorker,
      queue: "squid_mesh",
      args: %{"step" => "announce_digest"}
    )

    assert :ok = MinimalHostApp.RuntimeHarness.wait_for_execution()

    assert {:ok, runs} = WorkflowRuns.list_daily_digest_runs()
    run = Enum.find(runs, fn run -> not MapSet.member?(existing_run_ids, run.id) end)

    assert %SquidMesh.Run{} = run
    assert run.trigger == :daily_digest
    assert is_binary(run.payload.digest_date)
    assert run.payload.channel == "ops"
  end

  test "rejects a manual approval workflow through the host boundary" do
    assert {:ok, run} = WorkflowRuns.start_manual_approval(%{account_id: "acct_review_123"})

    assert :ok = MinimalHostApp.RuntimeHarness.wait_for_execution()
    assert {:ok, paused_run} = WorkflowRuns.inspect_run(run.id, include_history: true)

    assert paused_run.status == :paused
    assert paused_run.current_step == :wait_for_approval

    assert {:ok, resumed_run} =
             WorkflowRuns.reject_run(run.id, %{actor: "ops_456", comment: "rejected"})

    assert resumed_run.status == :running
    assert resumed_run.current_step == :record_rejection

    assert :ok = MinimalHostApp.RuntimeHarness.wait_for_execution()
    assert {:ok, completed_run} = MinimalHostApp.RuntimeHarness.await_terminal_run(run.id)
    assert {:ok, completed_history} = WorkflowRuns.inspect_run(run.id, include_history: true)

    assert completed_run.status == :completed
    assert completed_run.context.approval.account_id == "acct_review_123"
    assert completed_run.context.approval.status == "rejected"
    assert completed_run.context.approval.decision == "rejected"
    assert completed_run.context.approval.actor == "ops_456"
    assert completed_run.context.approval.comment == "rejected"

    assert Enum.map(completed_history.audit_events, &{&1.type, &1.step, &1.actor}) == [
             {:paused, :wait_for_approval, nil},
             {:rejected, :wait_for_approval, "ops_456"}
           ]
  end

  test "runs the documented smoke path" do
    assert %{
             payment_recovery: payment_recovery,
             dependency_recovery: dependency_recovery,
             manual_approval: manual_approval,
             manual_digest: manual_digest,
             daily_digest: daily_digest
           } =
             Smoke.run_all!()

    assert payment_recovery.status == :completed
    assert payment_recovery.context.notification.channel == "email"
    assert payment_recovery.context.gateway_check.status == "retry_required"

    assert dependency_recovery.status == :completed
    assert dependency_recovery.context.notification.channel == "email"

    assert manual_approval.status == :completed
    assert manual_approval.context.approval.status == "approved"

    assert manual_digest.status == :completed
    assert manual_digest.trigger == :manual_digest

    assert daily_digest.status == :completed
    assert daily_digest.trigger == :daily_digest
  end

  test "runs the cancellation smoke path" do
    assert %SquidMesh.Run{} = run = Smoke.run_cancellation!()
    assert run.status == :cancelled
  end

  defp endpoint_url(port, path) do
    "http://127.0.0.1:#{port}#{path}"
  end
end
