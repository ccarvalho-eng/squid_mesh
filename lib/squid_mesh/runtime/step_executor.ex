defmodule SquidMesh.Runtime.StepExecutor do
  @moduledoc """
  Executes one workflow step through Jido and persists the outcome.

  This module is the runtime boundary where declarative workflow definitions are
  turned into durable step execution and persisted run progress.
  """

  require Logger

  alias SquidMesh.AttemptStore
  alias SquidMesh.Config
  alias SquidMesh.Observability
  alias SquidMesh.Run
  alias SquidMesh.RunStore
  alias SquidMesh.Runtime.StepInput
  alias SquidMesh.Runtime.StepExecutor.Outcome
  alias SquidMesh.StepRunStore
  alias SquidMesh.Workflow.Definition, as: WorkflowDefinition

  @type execution_error ::
          :not_found
          | {:invalid_workflow, module() | String.t()}
          | {:invalid_step, atom() | String.t() | nil}
          | {:dispatch_failed, term()}
          | {:invalid_run, Ecto.Changeset.t()}
          | {:invalid_transition, Run.status(), Run.status()}
          | {:unknown_transition, atom(), atom()}
          | {:unknown_step, atom()}
          | {:missing_config, [atom()]}

  @type expected_step :: atom() | String.t() | nil

  @spec execute(Ecto.UUID.t(), expected_step(), keyword()) ::
          :ok | {:error, execution_error() | term()}
  def execute(run_id, expected_step \\ nil, overrides \\ []) when is_binary(run_id) do
    with {:ok, normalized_expected_step} <- StepInput.deserialize_expected_step(expected_step),
         {:ok, config} <- Config.load(overrides),
         {:ok, run} <- RunStore.get_run(config.repo, run_id) do
      execute_run(config, run, normalized_expected_step)
    end
  end

  @spec execute_run(Config.t(), Run.t(), atom() | nil) ::
          :ok | {:error, execution_error() | term()}
  defp execute_run(_config, %Run{status: status}, _expected_step)
       when status in [:completed, :failed, :cancelled] do
    :ok
  end

  defp execute_run(config, %Run{status: :cancelling} = run, _expected_step) do
    case RunStore.transition_run(config.repo, run.id, :cancelled, %{
           current_step: nil
         }) do
      {:ok, _cancelled_run} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_run(config, %Run{workflow: workflow} = run, expected_step)
       when is_atom(workflow) do
    with {:ok, definition} <- WorkflowDefinition.load(workflow) do
      case resolve_execution_step(config.repo, definition, run, expected_step) do
        {:ok, execution_step} ->
          with {:ok, step} <- WorkflowDefinition.step(definition, execution_step),
               {:ok, running_run} <- ensure_running(config.repo, run, definition, execution_step),
               candidate_input = StepInput.build_step_input(running_run),
               {:ok, step_run, execution_mode} <-
                 StepRunStore.begin_step(
                   config.repo,
                   running_run.id,
                   execution_step,
                   candidate_input
                 ) do
            input = execution_input(step_run, candidate_input)

            maybe_execute_step(
              execution_mode,
              execution_step,
              step,
              input,
              config,
              definition,
              running_run,
              step_run
            )
          end

        :skip ->
          :ok

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp execute_run(_config, %Run{current_step: current_step}, _expected_step) do
    {:error, {:invalid_step, current_step}}
  end

  @spec ensure_running(module(), Run.t(), WorkflowDefinition.t(), atom()) ::
          {:ok, Run.t()} | {:error, execution_error() | term()}
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

  @spec maybe_execute_step(
          :execute | :skip,
          atom(),
          WorkflowDefinition.step(),
          map(),
          Config.t(),
          WorkflowDefinition.t(),
          Run.t(),
          SquidMesh.Persistence.StepRun.t()
        ) :: :ok | {:error, execution_error() | term()}
  defp maybe_execute_step(
         :skip,
         current_step,
         _step,
         _input,
         _config,
         _definition,
         run,
         step_run
       ) do
    Observability.emit_step_skipped(run, current_step, "already_#{step_run.status}")
    :ok
  end

  defp maybe_execute_step(
         :execute,
         current_step,
         step,
         input,
         config,
         definition,
         run,
         step_run
       ) do
    with {:ok, attempt} <- AttemptStore.begin_attempt(config.repo, step_run.id) do
      attempt_number = attempt.attempt_number

      Observability.with_step_metadata(run, current_step, attempt_number, fn ->
        Observability.emit_step_started(run, current_step, attempt_number)

        started_at = System.monotonic_time()

        current_step
        |> Outcome.execute_step(step, input, run)
        |> Outcome.persist_execution_result(
          current_step,
          config,
          definition,
          run,
          step_run.id,
          attempt.id,
          attempt_number,
          started_at
        )
      end)
    end
  end

  @spec resolve_execution_step(module(), WorkflowDefinition.t(), Run.t(), atom() | nil) ::
          {:ok, atom()} | :skip | {:error, execution_error() | term()}
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

  defp running_step(definition, execution_step) do
    if WorkflowDefinition.dependency_mode?(definition), do: nil, else: execution_step
  end

  defp execution_input(step_run, fallback_input) do
    step_run.input
    |> Kernel.||(fallback_input)
    |> StepInput.normalize_map_keys()
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
end
