defmodule SquidMesh.Runtime.Unblocker do
  @moduledoc """
  Resumes runs that are intentionally paused for manual intervention.

  This module validates the paused step, completes its durable running step
  state, and hands control back to the normal success progression path.
  """

  import Ecto.Query

  alias SquidMesh.AttemptStore
  alias SquidMesh.Config
  alias SquidMesh.Observability
  alias SquidMesh.RunStore
  alias SquidMesh.RunStore.Persistence
  alias SquidMesh.Persistence.Run, as: RunRecord
  alias SquidMesh.Persistence.StepAttempt
  alias SquidMesh.Persistence.StepRun
  alias SquidMesh.Run
  alias SquidMesh.RunStore.Serialization
  alias SquidMesh.Runtime.Dispatcher
  alias SquidMesh.StepRunStore
  alias SquidMesh.Workflow.Definition, as: WorkflowDefinition

  @spec unblock(Config.t(), Run.t()) :: :ok | {:error, term()}
  def unblock(%Config{} = config, %Run{workflow: workflow} = run) when is_atom(workflow) do
    case config.repo.transaction(fn ->
           with {:ok, {paused_run, run_record}} <- locked_paused_run(config.repo, run.id),
                {:ok, step_name} <- paused_step_name(paused_run),
                {:ok, definition} <- WorkflowDefinition.load(workflow),
                {:ok, _pause_step} <- paused_step_definition(definition, step_name),
                {:ok, mapped_output} <-
                  WorkflowDefinition.apply_output_mapping(definition, step_name, %{}),
                {:ok, step_run} <- running_step_run(config.repo, paused_run.id, step_name),
                {:ok, attempt} <- running_attempt(config.repo, step_run.id),
                {:ok, _attempt} <- AttemptStore.complete_attempt(config.repo, attempt.id),
                {:ok, _step_run} <-
                  StepRunStore.complete_step(config.repo, step_run.id, mapped_output),
                {:ok, resume_result} <-
                  resume_paused_run(
                    config.repo,
                    run_record,
                    paused_run,
                    definition,
                    step_name,
                    mapped_output
                  ) do
             {paused_run, step_name, attempt, resume_result}
           else
             {:error, reason} -> config.repo.rollback(reason)
           end
         end) do
      {:ok, {paused_run, step_name, attempt, resume_result}} ->
        Observability.emit_step_completed(
          paused_run,
          step_name,
          attempt.attempt_number,
          Observability.duration_since(attempt.inserted_at)
        )

        finalize_unblock_resume(config, paused_run, resume_result)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def unblock(%Config{}, %Run{workflow: workflow}) do
    {:error, {:invalid_workflow, workflow}}
  end

  defp locked_paused_run(repo, run_id) do
    case locked_run_record(repo, run_id) do
      %RunRecord{status: "paused"} = run_record ->
        {:ok, {Serialization.to_public_run(run_record), run_record}}

      %RunRecord{status: status} ->
        {:error, {:invalid_transition, Serialization.deserialize_status(status), :running}}

      nil ->
        {:error, :not_found}
    end
  end

  defp paused_step_name(%Run{current_step: step_name}) when is_atom(step_name),
    do: {:ok, step_name}

  defp paused_step_name(%Run{current_step: step_name}), do: {:error, {:invalid_step, step_name}}

  defp paused_step_definition(definition, step_name) do
    with {:ok, step} <- WorkflowDefinition.step(definition, step_name) do
      case step do
        %{module: :pause} -> {:ok, step}
        _other -> {:error, {:invalid_step, step_name}}
      end
    end
  end

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

  defp resume_paused_run(repo, run_record, paused_run, definition, step_name, mapped_output) do
    attrs = %{
      context: merged_context(paused_run, mapped_output),
      last_error: nil
    }

    case WorkflowDefinition.transition_target(definition, step_name, :ok) do
      {:ok, :complete} ->
        with {:ok, updated_run} <-
               Persistence.update_run_record(
                 repo,
                 run_record,
                 Persistence.transition_changeset_attrs(
                   :completed,
                   Map.put(attrs, :current_step, nil)
                 )
               ) do
          {:ok,
           %{run: updated_run, from_status: :paused, to_status: :completed, dispatch?: false}}
        end

      {:ok, next_step} when is_atom(next_step) ->
        with {:ok, updated_run} <-
               Persistence.update_run_record(
                 repo,
                 run_record,
                 Persistence.transition_changeset_attrs(
                   :running,
                   Map.put(attrs, :current_step, next_step)
                 )
               ) do
          {:ok, %{run: updated_run, from_status: :paused, to_status: :running, dispatch?: true}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finalize_unblock_resume(_config, _paused_run, %{
         run: run,
         from_status: from,
         to_status: to,
         dispatch?: false
       }) do
    Observability.emit_run_transition(run, from, to)
    :ok
  end

  defp finalize_unblock_resume(%Config{} = config, _paused_run, %{
         run: run,
         from_status: from,
         to_status: to,
         dispatch?: true
       }) do
    Observability.emit_run_transition(run, from, to)

    case Dispatcher.dispatch_run(config, run, []) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        dispatch_error = %{
          message: "failed to dispatch workflow step",
          next_step: run.current_step,
          cause: normalize_dispatch_cause(reason)
        }

        case RunStore.transition_run(config.repo, run.id, :failed, %{
               context: run.context,
               current_step: run.current_step,
               last_error: dispatch_error
             }) do
          {:ok, _failed_run} -> {:error, {:dispatch_failed, reason}}
          {:error, transition_reason} -> {:error, transition_reason}
        end
    end
  end

  defp merged_context(%Run{} = run, mapped_output) do
    Map.merge(run.context || %{}, mapped_output)
  end

  defp normalize_dispatch_cause({:dispatch_failed, reason}), do: normalize_dispatch_cause(reason)

  defp normalize_dispatch_cause(%{__struct__: _module} = error),
    do: %{message: Exception.message(error)}

  defp normalize_dispatch_cause(reason), do: reason

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
