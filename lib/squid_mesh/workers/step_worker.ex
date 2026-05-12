defmodule SquidMesh.Workers.StepWorker do
  @moduledoc """
  Oban worker that executes a single Squid Mesh workflow step.

  Oban handles durable delivery while the runtime decides how a workflow run
  advances after the step completes. The same worker also handles compensation
  jobs, which omit a `step` argument and instead walk persisted completed step
  history for a failed run.
  """

  use Oban.Worker, queue: :squid_mesh, max_attempts: 1

  require Logger

  alias SquidMesh.Observability
  alias SquidMesh.Runtime.StepExecutor

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{args: %{"run_id" => run_id, "compensate" => true}})
      when is_binary(run_id) do
    Observability.with_run_metadata(
      %SquidMesh.Run{id: run_id, workflow: nil, trigger: nil, status: nil, current_step: nil},
      fn ->
        try do
          case StepExecutor.compensate(run_id) do
            :ok ->
              :ok

            {:error, reason} = error ->
              Logger.error("compensation execution failed: #{inspect(reason)}")
              error
          end
        rescue
          exception ->
            Logger.error("""
            unexpected compensation exception: #{Exception.format(:error, exception, __STACKTRACE__)}
            """)

            {:error, {:exception, Exception.message(exception)}}
        end
      end
    )
  end

  def perform(%Oban.Job{args: %{"run_id" => run_id, "step" => step}})
      when is_binary(run_id) and is_binary(step) do
    Observability.with_run_metadata(
      %SquidMesh.Run{id: run_id, workflow: nil, trigger: nil, status: nil, current_step: step},
      fn ->
        try do
          case StepExecutor.execute(run_id, step) do
            :ok ->
              :ok

            {:error, reason} = error ->
              Logger.error("step execution failed: #{inspect(reason)}")
              error
          end
        rescue
          exception ->
            Logger.error("""
            unexpected step execution exception: #{Exception.format(:error, exception, __STACKTRACE__)}
            """)

            {:error, {:exception, Exception.message(exception)}}
        end
      end
    )
  end

  def perform(%Oban.Job{} = job) do
    {:error, {:invalid_job_args, job.args}}
  end
end
