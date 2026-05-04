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
  alias SquidMesh.StepRunStore
  alias SquidMesh.Workflow.Definition, as: WorkflowDefinition

  @type prepare_result ::
          {:execute, PreparedStep.t()}
          | {:skip, PreparedStep.t()}
          | :skip
          | {:error, term()}

  @spec prepare(Config.t(), WorkflowDefinition.t(), Run.t(), atom() | nil) :: prepare_result()
  def prepare(%Config{} = config, definition, %Run{} = run, expected_step) do
    case resolve_execution_step(config.repo, definition, run, expected_step) do
      {:ok, execution_step} ->
        with {:ok, step} <- WorkflowDefinition.step(definition, execution_step),
             {:ok, input_mapping} <-
               WorkflowDefinition.step_input_mapping(definition, execution_step),
             {:ok, running_run} <- ensure_running(config.repo, run, definition, execution_step),
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
            :execute -> {:execute, prepared}
            :skip -> {:skip, prepared}
          end
        end

      :skip ->
        :skip

      {:error, _reason} = error ->
        error
    end
  end

  @spec ensure_running(module(), Run.t(), WorkflowDefinition.t(), atom()) ::
          {:ok, Run.t()} | {:error, term()}
  defp ensure_running(
         repo,
         %Run{status: :pending, id: run_id},
         definition,
         execution_step
       ) do
    case RunStore.transition_run(repo, run_id, :running, %{
           current_step: running_step(definition, execution_step)
         }) do
      {:ok, running_run} ->
        {:ok, running_run}

      {:error, {:invalid_transition, :running, :running}} ->
        RunStore.get_run(repo, run_id)

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
    case RunStore.transition_run(repo, run_id, :running, %{
           current_step: running_step(definition, execution_step)
         }) do
      {:ok, running_run} ->
        {:ok, running_run}

      {:error, {:invalid_transition, :running, :running}} ->
        RunStore.get_run(repo, run_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_running(_repo, %Run{} = run, _definition, _execution_step), do: {:ok, run}

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
end
