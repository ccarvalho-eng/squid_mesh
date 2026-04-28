defmodule MinimalHostApp.Smoke do
  @moduledoc """
  Repeatable smoke-test entrypoint for the example host app.
  """

  alias MinimalHostApp.Cron
  alias MinimalHostApp.RuntimeHarness
  alias MinimalHostApp.WorkflowRuns

  @poll_attempts 20

  @spec run!() :: SquidMesh.Run.t()
  def run! do
    RuntimeHarness.ensure_runtime_started()

    {server_pid, port} =
      RuntimeHarness.start_gateway_server(
        fn _attempt -> RuntimeHarness.success_gateway_response("retry_required") end,
        1
      )

    attrs = %{
      account_id: "acct_demo",
      invoice_id: "inv_demo",
      attempt_id: "attempt_demo",
      gateway_url: RuntimeHarness.endpoint_url(port, "/gateway")
    }

    with {:ok, run} <- WorkflowRuns.start_payment_recovery(attrs),
         :ok <- RuntimeHarness.wait_for_execution(),
         {:ok, inspected_run} <-
           RuntimeHarness.await_terminal_run(run.id, attempts: @poll_attempts) do
      IO.puts("started run #{run.id} for #{inspect(run.workflow)}")
      RuntimeHarness.stop_gateway_server(server_pid)

      unless inspected_run.id == run.id and inspected_run.status == :completed do
        raise "unexpected smoke result"
      end

      inspected_run
    else
      {:error, reason} ->
        raise "smoke test failed: #{inspect(reason)}"
    end
  end

  @spec run_all!() :: %{payment_recovery: SquidMesh.Run.t(), daily_digest: SquidMesh.Run.t()}
  def run_all! do
    payment_recovery = run!()

    with :ok <- run_cron_digest(),
         {:ok, [cron_run]} <- WorkflowRuns.list_daily_digest_runs() do
      unless cron_run.status == :completed and cron_run.trigger == :daily_digest do
        raise "unexpected cron smoke result"
      end

      %{
        payment_recovery: payment_recovery,
        daily_digest: cron_run
      }
    else
      {:error, reason} ->
        raise "cron smoke test failed: #{inspect(reason)}"
    end
  end

  @spec run_cancellation!() :: SquidMesh.Run.t()
  def run_cancellation! do
    RuntimeHarness.ensure_runtime_started()

    case run_cancellation_smoke() do
      {:ok, cancelled_run} ->
        cancelled_run

      {:error, reason} ->
        raise "cancellation smoke test failed: #{inspect(reason)}"
    end
  end

  @spec wait_for_execution() :: :ok
  defp wait_for_execution do
    RuntimeHarness.wait_for_execution()
  end

  @spec run_cron_digest() :: :ok
  defp run_cron_digest do
    Cron.evaluate!()
    wait_for_execution()
  end

  @spec run_cancellation_smoke() :: {:ok, SquidMesh.Run.t()} | {:error, term()}
  defp run_cancellation_smoke do
    with {:ok, run} <- WorkflowRuns.start_cancellable_wait(%{account_id: "acct_demo"}),
         :ok <- wait_for_execution(),
         {:ok, cancelling_run} <- WorkflowRuns.cancel_run(run.id),
         :ok <- ensure_cancelling(cancelling_run),
         :ok <- RuntimeHarness.perform_scheduled_step!(run.id, "record_delivery"),
         {:ok, cancelled_run} <-
           RuntimeHarness.await_terminal_run(run.id, attempts: @poll_attempts) do
      {:ok, cancelled_run}
    else
      {:error, _reason} = error -> error
      other -> {:error, other}
    end
  end

  @spec ensure_cancelling(SquidMesh.Run.t()) :: :ok | {:error, :unexpected_cancellation_status}
  defp ensure_cancelling(%SquidMesh.Run{status: :cancelling}), do: :ok
  defp ensure_cancelling(%SquidMesh.Run{}), do: {:error, :unexpected_cancellation_status}
end
