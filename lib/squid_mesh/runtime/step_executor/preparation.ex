defmodule SquidMesh.Runtime.StepExecutor.Preparation do
  @moduledoc """
  Prepares a runnable workflow step for execution.

  This phase resolves which step a worker is allowed to execute, ensures the
  run is in the correct lifecycle state, claims durable step-run state, and
  builds the normalized input that execution will consume.
  """

  alias SquidMesh.Config
  alias SquidMesh.Run
  alias SquidMesh.RunStore
  alias SquidMesh.Runtime.StepExecutor.PreparedStep
  alias SquidMesh.Runtime.StepInput
  alias SquidMesh.Runtime.StepRecovery
  alias SquidMesh.StepRunStore
  alias SquidMesh.Workflow.Definition, as: WorkflowDefinition

  @type prepare_result ::
          {:execute, PreparedStep.t()}
          | {:reconcile, PreparedStep.t()}
          | {:skip, PreparedStep.t()}
          | {:cancel, Run.t()}
          | :skip
          | {:error, term()}
  @spec prepare(Config.t(), WorkflowDefinition.t(), Run.t(), atom() | nil) :: prepare_result()
  def prepare(%Config{} = config, definition, %Run{} = run, expected_step) do
    # Lock the run before claiming a step so stale workers cannot start side
    # effects after cancellation or another terminal transition wins the race.
    case config.repo.transaction(fn ->
           with {:ok, locked_run} <- RunStore.get_run_for_update(config.repo, run.id) do
             {result, events} = do_prepare(config, definition, locked_run, expected_step)
             {:prepared, result, events}
           else
             {:error, reason} -> config.repo.rollback(reason)
           end
         end) do
      {:ok, {:prepared, {:recover_stale, prepared}, events}} ->
        emit_post_commit_events(events)
        recover_existing_step(config, prepared)

      {:ok, {:prepared, result, events}} ->
        emit_post_commit_events(events)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_prepare(%Config{} = config, definition, %Run{status: status} = run, expected_step)
       when status in [:pending, :running, :retrying] do
    case resolve_execution_step(config.repo, definition, run, expected_step) do
      {:ok, execution_step} ->
        with {:ok, step} <- WorkflowDefinition.step(definition, execution_step),
             {:ok, input_mapping} <-
               WorkflowDefinition.step_input_mapping(definition, execution_step),
             {:ok, running_run, events} <-
               ensure_running(config.repo, run, definition, execution_step),
             candidate_input = StepInput.build_step_input(running_run, input_mapping),
             {:ok, step_run, execution_mode} <-
               StepRunStore.begin_step(
                 config.repo,
                 running_run.id,
                 execution_step,
                 candidate_input
               ) do
          prepared = %PreparedStep{
            config: config,
            definition: definition,
            run: running_run,
            step_name: execution_step,
            step: step,
            step_run: step_run,
            input: execution_input(step_run, candidate_input)
          }

          case execution_mode do
            :execute -> {{:execute, prepared}, events}
            :skip -> {prepare_existing_step(config, prepared), events}
          end
        end

      :skip ->
        {:skip, []}

      {:error, _reason} = error ->
        {error, []}
    end
  end

  defp do_prepare(_config, _definition, %Run{status: :cancelling} = run, _expected_step) do
    {{:cancel, run}, []}
  end

  defp do_prepare(_config, _definition, %Run{}, _expected_step), do: {:skip, []}

  @spec ensure_running(module(), Run.t(), WorkflowDefinition.t(), atom()) ::
          {:ok, Run.t(), [tuple()]} | {:error, term()}
  defp ensure_running(
         repo,
         %Run{status: :pending, id: run_id},
         definition,
         execution_step
       ) do
    case RunStore.transition_run_silent(repo, run_id, :running, %{
           current_step: running_step(definition, execution_step)
         }) do
      {:ok, {running_run, from_status, to_status}} ->
        {:ok, running_run, [run_transition_event(running_run, from_status, to_status)]}

      {:error, {:invalid_transition, :running, :running}} ->
        get_already_running_run(repo, run_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_running(
         repo,
         %Run{status: :retrying, id: run_id},
         definition,
         execution_step
       ) do
    case RunStore.transition_run_silent(repo, run_id, :running, %{
           current_step: running_step(definition, execution_step)
         }) do
      {:ok, {running_run, from_status, to_status}} ->
        {:ok, running_run, [run_transition_event(running_run, from_status, to_status)]}

      {:error, {:invalid_transition, :running, :running}} ->
        get_already_running_run(repo, run_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_running(_repo, %Run{} = run, _definition, _execution_step), do: {:ok, run, []}

  @spec resolve_execution_step(module(), WorkflowDefinition.t(), Run.t(), atom() | nil) ::
          {:ok, atom()} | :skip | {:error, term()}
  defp resolve_execution_step(
         repo,
         definition,
         %Run{current_step: current_step, id: run_id},
         expected_step
       ) do
    cond do
      WorkflowDefinition.dependency_mode?(definition) and is_atom(expected_step) ->
        resolve_dependency_execution_step(repo, run_id, expected_step)

      is_atom(current_step) and (is_nil(expected_step) or expected_step == current_step) ->
        {:ok, current_step}

      not is_nil(expected_step) and is_atom(expected_step) and current_step != expected_step ->
        :skip

      true ->
        {:error, {:invalid_step, current_step}}
    end
  end

  defp resolve_dependency_execution_step(repo, run_id, expected_step) do
    case StepRunStore.get_step_run(repo, run_id, expected_step) do
      %SquidMesh.Persistence.StepRun{status: status} when status in ["pending", "failed"] ->
        {:ok, expected_step}

      %SquidMesh.Persistence.StepRun{} ->
        :skip

      nil ->
        :skip
    end
  end

  defp running_step(definition, execution_step) do
    if WorkflowDefinition.dependency_mode?(definition), do: nil, else: execution_step
  end

  defp execution_input(step_run, fallback_input) do
    step_run.input
    |> Kernel.||(fallback_input)
    |> StepInput.normalize_map_keys()
  end

  defp get_already_running_run(repo, run_id) do
    with {:ok, run} <- RunStore.get_run(repo, run_id) do
      {:ok, run, []}
    end
  end

  defp emit_post_commit_events(events) do
    Enum.each(events, fn {:run_transition, run, from_status, to_status} ->
      SquidMesh.Observability.emit_run_transition(run, from_status, to_status)
    end)
  end

  defp run_transition_event(run, from_status, to_status) do
    {:run_transition, run, from_status, to_status}
  end

  defp prepare_existing_step(_config, %PreparedStep{step_run: %{status: "completed"}} = prepared) do
    {:reconcile, prepared}
  end

  defp prepare_existing_step(
         _config,
         %PreparedStep{step_run: %{status: "running"}} = prepared
       ) do
    {:recover_stale, prepared}
  end

  defp prepare_existing_step(_config, prepared), do: {:skip, prepared}

  defp recover_existing_step(
         %Config{stale_step_timeout: stale_step_timeout} = config,
         %PreparedStep{} = prepared
       ) do
    # A duplicate delivery normally skips a running step. If the previous worker
    # died, reclaim outside the run lock, then re-enter preparation. This keeps
    # the lock order compatible with normal completion: attempt/step before run.
    case StepRecovery.reclaim_stale_running_step(
           config.repo,
           prepared.step_run,
           stale_step_timeout
         ) do
      {:ok, :reclaimed} ->
        prepare(config, prepared.definition, prepared.run, prepared.step_name)

      {:ok, _not_reclaimed} ->
        {:skip, prepared}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
