defmodule SquidMesh.Workers.CronTriggerWorker do
  @moduledoc """
  Oban worker that starts a workflow run from a cron trigger.

  Cron activation stays thin here: Oban owns recurring scheduling and Squid
  Mesh reuses the same public `start_run/4` path used by host applications.
  """

  use Oban.Worker, queue: :squid_mesh, max_attempts: 1

  alias SquidMesh.Workflow.Definition, as: WorkflowDefinition

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: Oban.Worker.result()
  def perform(%Oban.Job{args: %{"workflow" => workflow_name, "trigger" => trigger_name}})
      when is_binary(workflow_name) and is_binary(trigger_name) do
    with {:ok, workflow, definition} <- WorkflowDefinition.load_serialized(workflow_name),
         trigger when is_atom(trigger) <-
           WorkflowDefinition.deserialize_trigger(definition, trigger_name),
         {:ok, _run} <- SquidMesh.start_run(workflow, trigger, %{}) do
      :ok
    else
      {:error, reason} ->
        {:error, reason}

      invalid_trigger ->
        {:error, {:invalid_trigger, invalid_trigger}}
    end
  end

  def perform(%Oban.Job{} = job) do
    {:error, {:invalid_job_args, job.args}}
  end
end
