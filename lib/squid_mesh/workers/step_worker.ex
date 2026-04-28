defmodule SquidMesh.Workers.StepWorker do
  @moduledoc """
  Oban worker that executes a single Squid Mesh workflow step.

  Oban handles durable delivery while the runtime decides how a workflow run
  advances after the step completes.
  """

  use Oban.Worker, queue: :squid_mesh, max_attempts: 1

  require Logger

  alias SquidMesh.Runtime.StepExecutor

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{args: %{"run_id" => run_id, "step" => step}})
      when is_binary(run_id) and is_binary(step) do
    try do
      case StepExecutor.execute(run_id, step) do
        :ok ->
          :ok

        {:error, reason} = error ->
          Logger.error("step execution failed for run #{run_id}: #{inspect(reason)}")
          error
      end
    rescue
      exception ->
        Logger.error("""
        unexpected step execution exception for run #{run_id}: #{Exception.format(:error, exception, __STACKTRACE__)}
        """)

        {:error, {:exception, Exception.message(exception)}}
    end
  end

  def perform(%Oban.Job{} = job) do
    {:error, {:invalid_job_args, job.args}}
  end
end
