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
  alias SquidMesh.Runtime.StepExecutor.Input
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
    with {:ok, normalized_expected_step} <- Input.deserialize_expected_step(expected_step),
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

  defp execute_run(_config, %Run{current_step: current_step}, expected_step)
       when not is_nil(expected_step) and is_atom(expected_step) and current_step != expected_step do
    :ok
  end

  defp execute_run(
         config,
         %Run{workflow: workflow, current_step: current_step} = run,
         _expected_step
       )
       when is_atom(workflow) and is_atom(current_step) do
    with {:ok, definition} <- WorkflowDefinition.load(workflow),
         {:ok, step} <- WorkflowDefinition.step(definition, current_step),
         {:ok, running_run} <- ensure_running(config.repo, run),
         input = Input.build_step_input(running_run),
         {:ok, step_run, execution_mode} <-
           StepRunStore.begin_step(config.repo, running_run.id, current_step, input) do
      maybe_execute_step(
        execution_mode,
        current_step,
        step,
        input,
        config,
        definition,
        running_run,
        step_run
      )
    end
  end

  defp execute_run(_config, %Run{current_step: current_step}, _expected_step) do
    {:error, {:invalid_step, current_step}}
  end

  @spec ensure_running(module(), Run.t()) :: {:ok, Run.t()} | {:error, execution_error() | term()}
  defp ensure_running(repo, %Run{status: :pending, current_step: current_step, id: run_id}) do
    RunStore.transition_run(repo, run_id, :running, %{current_step: current_step})
  end

  defp ensure_running(repo, %Run{status: :retrying, current_step: current_step, id: run_id}) do
    RunStore.transition_run(repo, run_id, :running, %{current_step: current_step})
  end

  defp ensure_running(_repo, %Run{} = run), do: {:ok, run}

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
end
