defmodule SquidMesh.Runtime.StepExecutor do
  @moduledoc """
  Executes one workflow step through Jido and persists the outcome.

  This module is the runtime boundary where declarative workflow definitions are
  turned into durable step execution and persisted run progress.
  """

  alias SquidMesh.AttemptStore
  alias SquidMesh.Config
  alias SquidMesh.Run
  alias SquidMesh.RunStore
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

  @spec execute(Ecto.UUID.t(), keyword()) :: :ok | {:error, execution_error() | term()}
  def execute(run_id, overrides \\ []) when is_binary(run_id) do
    with {:ok, config} <- Config.load(overrides),
         {:ok, run} <- RunStore.get_run(config.repo, run_id) do
      execute_run(config, run)
    end
  end

  @spec execute_run(Config.t(), Run.t()) :: :ok | {:error, execution_error() | term()}
  defp execute_run(_config, %Run{status: status})
       when status in [:completed, :failed, :cancelled] do
    :ok
  end

  defp execute_run(config, %Run{status: :cancelling} = run) do
    case RunStore.transition_run(config.repo, run.id, :cancelled, %{
           current_step: run.current_step
         }) do
      {:ok, _cancelled_run} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_run(config, %Run{workflow: workflow, current_step: current_step} = run)
       when is_atom(workflow) and is_atom(current_step) do
    with {:ok, definition} <- WorkflowDefinition.load(workflow),
         {:ok, action} <- WorkflowDefinition.step_module(definition, current_step),
         {:ok, running_run} <- ensure_running(config.repo, run),
         input = build_step_input(running_run),
         {:ok, step_run} <-
           StepRunStore.start_step(config.repo, running_run.id, current_step, input),
         attempt_number <- AttemptStore.attempt_count(config.repo, step_run.id) + 1 do
      current_step
      |> execute_action(action, input, running_run)
      |> persist_execution_result(config, definition, running_run, step_run.id, attempt_number)
    end
  end

  defp execute_run(_config, %Run{current_step: current_step}) do
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

  @spec build_step_input(Run.t()) :: map()
  defp build_step_input(%Run{payload: payload, context: context}) do
    payload
    |> Kernel.||(%{})
    |> Map.merge(context || %{})
    |> normalize_map_keys()
  end

  @spec execute_action(atom(), module(), map(), Run.t()) :: {:ok, map()} | {:error, term()}
  defp execute_action(step_name, action, input, run) do
    context = %{
      run_id: run.id,
      workflow: run.workflow,
      step: step_name,
      state: run.context || %{}
    }

    case Jido.Exec.run(action, input, context) do
      {:ok, output} when is_map(output) -> {:ok, output}
      {:ok, output, _extras} when is_map(output) -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec persist_execution_result(
          {:ok, map()} | {:error, term()},
          Config.t(),
          WorkflowDefinition.t(),
          Run.t(),
          Ecto.UUID.t(),
          pos_integer()
        ) :: :ok | {:error, execution_error() | term()}
  defp persist_execution_result(
         {:ok, output},
         config,
         definition,
         run,
         step_run_id,
         attempt_number
       ) do
    with {:ok, _attempt} <-
           AttemptStore.record_attempt(config.repo, step_run_id, attempt_number, "completed"),
         {:ok, _step_run} <- StepRunStore.complete_step(config.repo, step_run_id, output),
         {:ok, target} <- WorkflowDefinition.transition_target(definition, run.current_step, :ok) do
      advance_after_success(config, run, target, output)
    end
  end

  defp persist_execution_result(
         {:error, reason},
         config,
         _definition,
         run,
         step_run_id,
         attempt_number
       ) do
    error = normalize_error(reason)

    with {:ok, _attempt} <-
           AttemptStore.record_attempt(config.repo, step_run_id, attempt_number, "failed", %{
             error: error
           }),
         {:ok, _step_run} <- StepRunStore.fail_step(config.repo, step_run_id, error) do
      case RetryPolicy.resolve(run.workflow, run.current_step, attempt_number) do
        {:retry, _next_attempt} ->
          with {:ok, retried_run} <-
                 RunStore.transition_run(config.repo, run.id, :retrying, %{
                   current_step: run.current_step,
                   last_error: error
                 }) do
            case Dispatcher.dispatch_run(config, retried_run) do
              {:ok, _job} -> :ok
              {:error, reason} -> {:error, wrap_dispatch_error(reason)}
            end
          end

        _no_retry ->
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

  @spec advance_after_success(Config.t(), Run.t(), atom() | :complete, map()) ::
          :ok | {:error, execution_error() | term()}
  defp advance_after_success(config, run, :complete, output) do
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

  defp advance_after_success(config, run, next_step, output) when is_atom(next_step) do
    context = Map.merge(run.context || %{}, output)

    with {:ok, updated_run} <-
           RunStore.update_run(config.repo, run.id, %{
             context: context,
             current_step: next_step,
             last_error: nil
           }) do
      case Dispatcher.dispatch_run(config, updated_run) do
        {:ok, _job} -> :ok
        {:error, reason} -> {:error, wrap_dispatch_error(reason)}
      end
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

  @spec wrap_dispatch_error(term()) :: execution_error()
  defp wrap_dispatch_error({:dispatch_failed, _reason} = error), do: error
  defp wrap_dispatch_error(reason), do: {:dispatch_failed, reason}

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
