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
  alias SquidMesh.Runtime.BuiltInStep
  alias SquidMesh.Runtime.Dispatcher
  alias SquidMesh.Runtime.RetryPolicy
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
    with {:ok, normalized_expected_step} <- deserialize_expected_step(expected_step),
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

  defp execute_run(_config, %Run{current_step: current_step}, expected_step)
       when not is_nil(expected_step) and is_atom(expected_step) and current_step != expected_step do
    :ok
  end

  defp execute_run(config, %Run{status: :cancelling} = run, _expected_step) do
    case RunStore.transition_run(config.repo, run.id, :cancelled, %{
           current_step: run.current_step
         }) do
      {:ok, _cancelled_run} -> :ok
      {:error, reason} -> {:error, reason}
    end
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
         input = build_step_input(running_run),
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
        |> execute_step(step, input, run)
        |> persist_execution_result(
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

  @spec build_step_input(Run.t()) :: map()
  defp build_step_input(%Run{payload: payload, context: context}) do
    payload
    |> Kernel.||(%{})
    |> Map.merge(context || %{})
    |> normalize_map_keys()
  end

  @spec execute_step(atom(), WorkflowDefinition.step(), map(), Run.t()) ::
          {:ok, map(), keyword()} | {:error, term()}
  defp execute_step(_step_name, %{module: built_in_kind, opts: opts}, input, run)
       when built_in_kind in [:wait, :log] do
    BuiltInStep.execute(built_in_kind, opts, input, run)
  end

  defp execute_step(step_name, %{module: action}, input, run) do
    context = %{
      run_id: run.id,
      workflow: run.workflow,
      step: step_name,
      state: run.context || %{}
    }

    case Jido.Exec.run(action, input, context) do
      {:ok, output} when is_map(output) -> {:ok, output, []}
      {:ok, output, _extras} when is_map(output) -> {:ok, output, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec persist_execution_result(
          {:ok, map(), keyword()} | {:error, term()},
          Config.t(),
          WorkflowDefinition.t(),
          Run.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          pos_integer(),
          integer()
        ) :: :ok | {:error, execution_error() | term()}
  defp persist_execution_result(
         {:ok, output, execution_opts},
         config,
         definition,
         run,
         step_run_id,
         attempt_id,
         attempt_number,
         started_at
       ) do
    duration = System.monotonic_time() - started_at

    with {:ok, _attempt} <-
           AttemptStore.complete_attempt(config.repo, attempt_id),
         {:ok, _step_run} <- StepRunStore.complete_step(config.repo, step_run_id, output),
         {:ok, target} <- WorkflowDefinition.transition_target(definition, run.current_step, :ok) do
      Observability.emit_step_completed(run, run.current_step, attempt_number, duration)
      advance_after_success(config, run, target, output, execution_opts)
    end
  end

  defp persist_execution_result(
         {:error, reason},
         config,
         _definition,
         run,
         step_run_id,
         attempt_id,
         attempt_number,
         started_at
       ) do
    error = normalize_error(reason)
    duration = System.monotonic_time() - started_at

    with {:ok, _attempt} <-
           AttemptStore.fail_attempt(config.repo, attempt_id, error),
         {:ok, _step_run} <- StepRunStore.fail_step(config.repo, step_run_id, error) do
      Observability.emit_step_failed(run, run.current_step, attempt_number, duration, error)

      case RetryPolicy.resolve(run.workflow, run.current_step, attempt_number) do
        {:retry, _next_attempt, delay_ms} ->
          Logger.warning("workflow step failed; scheduling retry")
          Observability.emit_step_retry_scheduled(run, run.current_step, attempt_number, delay_ms)

          dispatch_opts = retry_dispatch_opts(delay_ms)

          case RunStore.transition_and_dispatch_run(
                 config.repo,
                 run.id,
                 :retrying,
                 %{
                   current_step: run.current_step,
                   last_error: error
                 },
                 fn retried_run -> Dispatcher.dispatch_run(config, retried_run, dispatch_opts) end
               ) do
            {:ok, _retried_run} ->
              :ok

            {:error, reason} ->
              mark_failed_after_retry_dispatch_error(config.repo, run, error, reason)
          end

        _no_retry ->
          Logger.error("workflow step failed")

          case RunStore.transition_run(config.repo, run.id, :failed, %{
                 current_step: run.current_step,
                 last_error: error
               }) do
            {:ok, _failed_run} -> :ok
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  @spec advance_after_success(Config.t(), Run.t(), atom() | :complete, map(), keyword()) ::
          :ok | {:error, execution_error() | term()}
  defp advance_after_success(config, run, :complete, output, _execution_opts) do
    context = Map.merge(run.context || %{}, output)

    case RunStore.transition_run(config.repo, run.id, :completed, %{
           context: context,
           current_step: nil,
           last_error: nil
         }) do
      {:ok, _completed_run} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp advance_after_success(config, run, next_step, output, execution_opts)
       when is_atom(next_step) do
    context = Map.merge(run.context || %{}, output)
    dispatch_opts = Keyword.take(execution_opts, [:schedule_in])

    case RunStore.update_and_dispatch_run(
           config.repo,
           run.id,
           %{
             context: context,
             current_step: next_step,
             last_error: nil
           },
           fn updated_run -> Dispatcher.dispatch_run(config, updated_run, dispatch_opts) end
         ) do
      {:ok, _updated_run} ->
        :ok

      {:error, reason} ->
        mark_failed_after_next_step_dispatch_error(
          config.repo,
          run.id,
          next_step,
          context,
          reason
        )
    end
  end

  @spec normalize_error(term()) :: map()
  defp normalize_error(%{__struct__: module} = error) do
    details =
      error
      |> Map.from_struct()
      |> Map.get(:details, %{})
      |> normalize_map_keys()

    base_error = %{message: Exception.message(error)}

    case details do
      %{} = empty when map_size(empty) == 0 ->
        Map.put(base_error, :type, inspect(module))

      %{} = detail_map ->
        Map.merge(base_error, detail_map)
    end
  end

  defp normalize_error(%{} = error), do: error
  defp normalize_error(error), do: %{message: inspect(error)}

  @spec mark_failed_after_next_step_dispatch_error(
          module(),
          Ecto.UUID.t(),
          atom(),
          map(),
          term()
        ) :: :ok | {:error, execution_error() | term()}
  defp mark_failed_after_next_step_dispatch_error(repo, run_id, next_step, context, reason) do
    dispatch_error = %{
      message: "failed to dispatch workflow step",
      next_step: next_step,
      cause: normalize_dispatch_cause(reason)
    }

    case RunStore.transition_run(repo, run_id, :failed, %{
           context: context,
           current_step: next_step,
           last_error: dispatch_error
         }) do
      {:ok, _failed_run} -> :ok
      {:error, transition_reason} -> {:error, transition_reason}
    end
  end

  @spec mark_failed_after_retry_dispatch_error(module(), Run.t(), map(), term()) ::
          :ok | {:error, execution_error() | term()}
  defp mark_failed_after_retry_dispatch_error(repo, run, step_error, reason) do
    dispatch_error = %{
      message: "failed to dispatch workflow step",
      failed_step: run.current_step,
      cause: step_error,
      dispatch_reason: normalize_dispatch_cause(reason)
    }

    case RunStore.transition_run(repo, run.id, :failed, %{
           current_step: run.current_step,
           last_error: dispatch_error
         }) do
      {:ok, _failed_run} -> :ok
      {:error, transition_reason} -> {:error, transition_reason}
    end
  end

  @spec normalize_dispatch_cause(term()) :: term()
  defp normalize_dispatch_cause({:dispatch_failed, reason}), do: normalize_dispatch_cause(reason)

  defp normalize_dispatch_cause(%{__struct__: _module} = error),
    do: %{message: Exception.message(error)}

  defp normalize_dispatch_cause(reason), do: reason

  @spec retry_dispatch_opts(non_neg_integer()) :: keyword()
  defp retry_dispatch_opts(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    [schedule_in: ceil(delay_ms / 1_000)]
  end

  defp retry_dispatch_opts(_delay_ms), do: []

  @spec deserialize_expected_step(expected_step()) ::
          {:ok, atom() | nil} | {:error, {:invalid_step, String.t()}}
  defp deserialize_expected_step(nil), do: {:ok, nil}
  defp deserialize_expected_step(step) when is_atom(step), do: {:ok, step}

  defp deserialize_expected_step(step) when is_binary(step) do
    try do
      {:ok, String.to_existing_atom(step)}
    rescue
      ArgumentError -> {:error, {:invalid_step, step}}
    end
  end

  @spec normalize_map_keys(map()) :: map()
  defp normalize_map_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        {to_existing_atom(key), normalize_value(value)}

      {key, value} ->
        {key, normalize_value(value)}
    end)
  end

  @spec normalize_value(term()) :: term()
  defp normalize_value(value) when is_map(value), do: normalize_map_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  @spec to_existing_atom(String.t()) :: atom() | String.t()
  defp to_existing_atom(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> key
    end
  end
end
