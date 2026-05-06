defmodule MinimalHostApp.Verification.RestartResilience do
  @moduledoc """
  Repeatable restart and deploy resilience checks for the example host app.

  This harness focuses on the runtime guarantees Squid Mesh claims today:
  queued work, delayed work, and retrying work should resume correctly after
  Oban restarts because durable run state and step jobs live in Postgres.
  """

  alias MinimalHostApp.RuntimeHarness
  alias MinimalHostApp.WorkflowRuns

  @poll_attempts 60

  @spec run!() :: %{
          queued_run: SquidMesh.Run.t(),
          delayed_run: SquidMesh.Run.t(),
          retry_run: SquidMesh.Run.t(),
          paused_run: SquidMesh.Run.t()
        }
  def run! do
    RuntimeHarness.ensure_runtime_started()

    %{
      queued_run: verify_queued_run_restart!(),
      delayed_run: verify_delayed_run_restart!(),
      retry_run: verify_retry_run_restart!(),
      paused_run: verify_paused_run_restart!()
    }
  end

  @spec verify_queued_run_restart!() :: SquidMesh.Run.t()
  defp verify_queued_run_restart! do
    {gateway_pid, port} =
      RuntimeHarness.start_gateway_server(
        fn _attempt -> RuntimeHarness.success_gateway_response("ok") end,
        2
      )

    try do
      attrs = %{
        account_id: "acct_resilience_queue",
        invoice_id: "inv_resilience_queue",
        attempt_id: "attempt_resilience_queue",
        gateway_url: RuntimeHarness.endpoint_url(port, "/gateway")
      }

      {:ok, run} = WorkflowRuns.start_payment_recovery(attrs)

      :ok = RuntimeHarness.restart_oban!()
      :ok = RuntimeHarness.wait_for_execution()

      {:ok, completed_run} =
        RuntimeHarness.await_terminal_run(run.id, attempts: @poll_attempts)

      unless completed_run.status == :completed do
        raise "expected queued run to complete after Oban restart"
      end

      completed_run
    after
      RuntimeHarness.stop_gateway_server(gateway_pid)
    end
  end

  @spec verify_delayed_run_restart!() :: SquidMesh.Run.t()
  defp verify_delayed_run_restart! do
    {:ok, run} = WorkflowRuns.start_cancellable_wait(%{account_id: "acct_resilience_delay"})

    :ok = RuntimeHarness.wait_for_execution()

    {:ok, delayed_run} = WorkflowRuns.inspect_run(run.id)

    unless delayed_run.status == :running and delayed_run.current_step == :record_delivery do
      raise "expected delayed run to be waiting on the next step"
    end

    :ok = RuntimeHarness.restart_oban!()
    :ok = RuntimeHarness.perform_scheduled_step!(run.id, "record_delivery")

    {:ok, completed_run} =
      RuntimeHarness.await_terminal_run(run.id, attempts: @poll_attempts)

    unless completed_run.status == :completed do
      raise "expected delayed run to complete after restart"
    end

    completed_run
  end

  @spec verify_retry_run_restart!() :: SquidMesh.Run.t()
  defp verify_retry_run_restart! do
    {:ok, run} =
      WorkflowRuns.start_retry_verification(%{
        attempt_id: "attempt_resilience_retry"
      })

    %{success: 1} = RuntimeHarness.drain_available_jobs(1)

    {:ok, retrying_run} = WorkflowRuns.inspect_run(run.id)

    unless retrying_run.status == :retrying and
             retrying_run.current_step == :exercise_retry do
      raise "expected retrying run before restart"
    end

    :ok = RuntimeHarness.restart_oban!()
    Process.sleep(1_100)
    :ok = RuntimeHarness.perform_scheduled_step!(run.id, "exercise_retry")

    {:ok, completed_run} =
      RuntimeHarness.await_terminal_run(run.id, attempts: @poll_attempts)

    {:ok, history_run} = WorkflowRuns.inspect_run(run.id, include_history: true)
    retry_step = Enum.find(history_run.step_runs, &(&1.step == :exercise_retry))

    unless (completed_run.status == :completed and retry_step) &&
             length(retry_step.attempts) == 2 do
      raise "expected retried run to complete with two attempts"
    end

    completed_run
  end

  @spec verify_paused_run_restart!() :: SquidMesh.Run.t()
  defp verify_paused_run_restart! do
    {:ok, run} = WorkflowRuns.start_manual_approval(%{account_id: "acct_resilience_pause"})
    :ok = RuntimeHarness.wait_for_execution()

    {:ok, paused_run} = WorkflowRuns.inspect_run(run.id, include_history: true)

    unless paused_run.status == :paused and paused_run.current_step == :wait_for_approval do
      raise "expected paused run before restart"
    end

    unless Enum.map(paused_run.audit_events, &{&1.type, &1.step}) == [
             {:paused, :wait_for_approval}
           ] do
      raise "expected paused audit history before restart"
    end

    :ok = RuntimeHarness.restart_oban!()

    {:ok, resumed_run} =
      WorkflowRuns.approve_run(
        run.id,
        %{actor: "ops_restart", comment: "approved", metadata: %{ticket: "RESTART-1"}}
      )

    unless resumed_run.status == :running and resumed_run.current_step == :record_approval do
      raise "expected resumed manual approval run after restart"
    end

    :ok = RuntimeHarness.wait_for_execution()

    {:ok, completed_run} =
      RuntimeHarness.await_terminal_run(run.id, attempts: @poll_attempts)

    {:ok, completed_history} = WorkflowRuns.inspect_run(run.id, include_history: true)

    unless completed_run.status == :completed and
             completed_run.context.approval.status == "approved" do
      raise "expected paused run to complete after restart and unblock"
    end

    unless Enum.map(completed_history.audit_events, &{&1.type, &1.step, &1.actor, &1.metadata}) ==
             [
               {:paused, :wait_for_approval, nil, nil},
               {:approved, :wait_for_approval, "ops_restart", %{ticket: "RESTART-1"}}
             ] do
      raise "expected approval audit history to survive restart"
    end

    completed_history
  end
end
