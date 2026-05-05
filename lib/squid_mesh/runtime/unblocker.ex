defmodule SquidMesh.Runtime.Unblocker do
  @moduledoc """
  Resumes runs that are intentionally paused for manual intervention.

  This module validates the paused step, completes its durable running step
  state, and hands control back to the normal success progression path.
  """

  alias SquidMesh.AttemptStore
  alias SquidMesh.Config
  alias SquidMesh.Persistence.StepAttempt
  alias SquidMesh.Persistence.StepRun
  alias SquidMesh.Run
  alias SquidMesh.Runtime.StepExecutor.Outcome
  alias SquidMesh.StepRunStore
  alias SquidMesh.Workflow.Definition, as: WorkflowDefinition

  @spec unblock(Config.t(), Run.t()) :: :ok | {:error, term()}
  def unblock(%Config{} = config, %Run{status: :paused, workflow: workflow} = run)
      when is_atom(workflow) do
    with {:ok, step_name} <- paused_step_name(run),
         {:ok, definition} <- WorkflowDefinition.load(workflow),
         {:ok, %{module: :pause}} <- WorkflowDefinition.step(definition, step_name),
         {:ok, step_run} <- running_step_run(config.repo, run.id, step_name),
         {:ok, attempt} <- running_attempt(config.repo, step_run.id),
         {:ok, _attempt} <- AttemptStore.complete_attempt(config.repo, attempt.id),
         {:ok, _step_run} <- StepRunStore.complete_step(config.repo, step_run.id, %{}) do
      Outcome.resume_paused_step(config, definition, run, step_name)
    end
  end

  def unblock(%Config{}, %Run{status: status}) do
    {:error, {:invalid_transition, status, :running}}
  end

  defp paused_step_name(%Run{current_step: step_name}) when is_atom(step_name),
    do: {:ok, step_name}

  defp paused_step_name(%Run{current_step: step_name}), do: {:error, {:invalid_step, step_name}}

  defp running_step_run(repo, run_id, step_name) do
    case StepRunStore.get_step_run(repo, run_id, step_name) do
      %StepRun{status: "running"} = step_run -> {:ok, step_run}
      _other -> {:error, {:invalid_step, step_name}}
    end
  end

  defp running_attempt(repo, step_run_id) do
    case AttemptStore.latest_attempt(repo, step_run_id) do
      %StepAttempt{status: "running"} = attempt -> {:ok, attempt}
      _other -> {:error, :not_found}
    end
  end
end
