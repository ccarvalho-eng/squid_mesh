defmodule MinimalHostApp.Smoke do
  @moduledoc """
  Repeatable smoke-test entrypoint for the example host app.
  """

  alias MinimalHostApp.Cron
  alias MinimalHostApp.RuntimeHarness
  alias MinimalHostApp.WorkflowRuns
  alias SquidMesh.Workers.CronTriggerWorker

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

  @spec run_all!() :: %{
          payment_recovery: SquidMesh.Run.t(),
          dependency_recovery: SquidMesh.Run.t(),
          daily_digest: SquidMesh.Run.t()
        }
  def run_all! do
    payment_recovery = run!()
    dependency_recovery = run_dependency_recovery!()

    with :ok <- run_cron_digest(),
         {:ok, cron_run} <- await_daily_digest_run(@poll_attempts) do
      unless cron_run.status == :completed and cron_run.trigger == :daily_digest do
        raise "unexpected cron smoke result"
      end

      %{
        payment_recovery: payment_recovery,
        dependency_recovery: dependency_recovery,
        daily_digest: cron_run
      }
    else
      {:error, reason} ->
        raise "cron smoke test failed: #{inspect(reason)}"
    end
  end

  @spec run_dependency_recovery!() :: SquidMesh.Run.t()
  def run_dependency_recovery! do
    attrs = %{
      account_id: "acct_dependency_demo",
      invoice_id: "inv_dependency_demo",
      attempt_id: "attempt_dependency_demo"
    }

    with {:ok, run} <- WorkflowRuns.start_dependency_recovery(attrs),
         :ok <- RuntimeHarness.wait_for_execution(),
         {:ok, inspected_run} <-
           RuntimeHarness.await_terminal_run(run.id, attempts: @poll_attempts) do
      unless inspected_run.id == run.id and inspected_run.status == :completed do
        raise "unexpected dependency recovery smoke result"
      end

      inspected_run
    else
      {:error, reason} ->
        raise "dependency recovery smoke test failed: #{inspect(reason)}"
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
    if manual_oban_testing?() do
      %Oban.Job{
        args: %{
          "workflow" => "Elixir.MinimalHostApp.Workflows.DailyDigest",
          "trigger" => "daily_digest"
        }
      }
      |> CronTriggerWorker.perform()
      |> case do
        :ok -> wait_for_execution()
        {:error, reason} -> raise "manual cron smoke trigger failed: #{inspect(reason)}"
      end
    else
      Cron.evaluate!()
      wait_for_execution()
    end
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

  @spec latest_daily_digest_run([SquidMesh.Run.t()]) ::
          {:ok, SquidMesh.Run.t()} | {:error, :missing_daily_digest_run}
  defp latest_daily_digest_run(runs) when is_list(runs) do
    case Enum.max_by(runs, & &1.inserted_at) do
      %SquidMesh.Run{} = run -> {:ok, run}
      _other -> {:error, :missing_daily_digest_run}
    end
  rescue
    Enum.EmptyError -> {:error, :missing_daily_digest_run}
  end

  @spec await_daily_digest_run(non_neg_integer()) ::
          {:ok, SquidMesh.Run.t()} | {:error, term()}
  defp await_daily_digest_run(0), do: {:error, :missing_daily_digest_run}

  defp await_daily_digest_run(attempts_remaining) when attempts_remaining > 0 do
    :ok = wait_for_execution()

    case WorkflowRuns.list_daily_digest_runs() do
      {:ok, []} ->
        Process.sleep(50)
        await_daily_digest_run(attempts_remaining - 1)

      {:ok, runs} ->
        with {:ok, run} <- latest_daily_digest_run(runs) do
          RuntimeHarness.await_terminal_run(run.id, attempts: @poll_attempts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp manual_oban_testing? do
    case Application.fetch_env(:minimal_host_app, Oban) do
      {:ok, config} -> Keyword.get(config, :testing) == :manual
      :error -> false
    end
  end
end
