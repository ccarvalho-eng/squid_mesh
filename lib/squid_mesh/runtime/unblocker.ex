defmodule SquidMesh.Runtime.Unblocker do
  @moduledoc """
  Resumes runs that are intentionally paused for manual intervention.

  This module validates the paused step, completes its durable running step
  state, and hands control back to the normal success progression path.
  """

  import Ecto.Query

  alias SquidMesh.AttemptStore
  alias SquidMesh.Config
  alias SquidMesh.Persistence.Run, as: RunRecord
  alias SquidMesh.Persistence.StepAttempt
  alias SquidMesh.Persistence.StepRun
  alias SquidMesh.Run
  alias SquidMesh.RunStore.Serialization
  alias SquidMesh.Runtime.StepExecutor.Outcome
  alias SquidMesh.StepRunStore
  alias SquidMesh.Workflow.Definition, as: WorkflowDefinition

  @spec unblock(Config.t(), Run.t()) :: :ok | {:error, term()}
  def unblock(%Config{} = config, %Run{workflow: workflow} = run) when is_atom(workflow) do
    case config.repo.transaction(fn ->
           with {:ok, paused_run} <- locked_paused_run(config.repo, run.id),
                {:ok, step_name} <- paused_step_name(paused_run),
                {:ok, definition} <- WorkflowDefinition.load(workflow),
                {:ok, %{module: :pause}} <- WorkflowDefinition.step(definition, step_name),
                {:ok, step_run} <- running_step_run(config.repo, paused_run.id, step_name),
                {:ok, attempt} <- running_attempt(config.repo, step_run.id),
                {:ok, _attempt} <- AttemptStore.complete_attempt(config.repo, attempt.id),
                {:ok, _step_run} <- StepRunStore.complete_step(config.repo, step_run.id, %{}),
                :ok <- Outcome.resume_paused_step(config, definition, paused_run, step_name) do
             :ok
           else
             {:error, reason} -> config.repo.rollback(reason)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp locked_paused_run(repo, run_id) do
    case locked_run_record(repo, run_id) do
      %RunRecord{status: "paused"} = run_record ->
        {:ok, Serialization.to_public_run(run_record)}

      %RunRecord{status: status} ->
        {:error, {:invalid_transition, Serialization.deserialize_status(status), :running}}

      nil ->
        {:error, :not_found}
    end
  end

  defp paused_step_name(%Run{current_step: step_name}) when is_atom(step_name),
    do: {:ok, step_name}

  defp paused_step_name(%Run{current_step: step_name}), do: {:error, {:invalid_step, step_name}}

  defp running_step_run(repo, run_id, step_name) do
    serialized_step = WorkflowDefinition.serialize_step(step_name)

    case locked_step_run(repo, run_id, serialized_step) do
      %StepRun{status: "running"} = step_run -> {:ok, step_run}
      _other -> {:error, {:invalid_step, step_name}}
    end
  end

  defp running_attempt(repo, step_run_id) do
    case locked_latest_attempt(repo, step_run_id) do
      %StepAttempt{status: "running"} = attempt -> {:ok, attempt}
      _other -> {:error, :not_found}
    end
  end

  defp locked_run_record(repo, run_id) do
    RunRecord
    |> where([run], run.id == ^run_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp locked_step_run(repo, run_id, step_name) do
    StepRun
    |> where([step_run], step_run.run_id == ^run_id and step_run.step == ^step_name)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp locked_latest_attempt(repo, step_run_id) do
    StepAttempt
    |> where([attempt], attempt.step_run_id == ^step_run_id)
    |> order_by([attempt],
      desc: attempt.attempt_number,
      desc: attempt.inserted_at,
      desc: attempt.id
    )
    |> limit(1)
    |> lock("FOR UPDATE")
    |> repo.one()
  end
end
