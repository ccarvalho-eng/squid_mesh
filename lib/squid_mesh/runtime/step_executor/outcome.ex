defmodule SquidMesh.Runtime.StepExecutor.Outcome do
  @moduledoc """
  Persistence and dispatch handling for completed step executions.

  `SquidMesh.Runtime.StepExecutor` delegates here after a step finishes so the
  orchestration flow stays readable while success, failure, retry, and dispatch
  error handling remain together.
  """

  require Logger

  alias SquidMesh.AttemptStore
  alias SquidMesh.Config
  alias SquidMesh.Observability
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
          | {:no_runnable_step, [atom()]}
          | {:unknown_transition, atom(), atom()}
          | {:unknown_step, atom()}
          | {:missing_config, [atom()]}

  @spec execute_step(atom(), WorkflowDefinition.step(), map(), Run.t()) ::
          {:ok, map(), keyword()} | {:error, term()}
  def execute_step(_step_name, %{module: built_in_kind, opts: opts}, input, run)
      when built_in_kind in [:wait, :log] do
    SquidMesh.Runtime.BuiltInStep.execute(built_in_kind, opts, input, run)
  end

  def execute_step(step_name, %{module: action}, input, run) do
    context = %{
      run_id: run.id,
      workflow: run.workflow,
      step: step_name,
      state: run.context || %{}
    }

    # Squid Mesh owns durable workflow-step retries through persisted attempts,
    # Oban scheduling, and the workflow DSL. Jido retries stay disabled here so
    # one workflow attempt maps to one action execution.
    case Jido.Exec.run(action, input, context, max_retries: 0) do
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
  def persist_execution_result(
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
    context = Map.merge(run.context || %{}, output)

    with {:ok, _attempt} <- AttemptStore.complete_attempt(config.repo, attempt_id),
         {:ok, _step_run} <- StepRunStore.complete_step(config.repo, step_run_id, output) do
      Observability.emit_step_completed(run, run.current_step, attempt_number, duration)

      case success_target(config.repo, definition, run) do
        {:ok, target} ->
          advance_after_success(config, run, target, output, execution_opts)

        {:error, reason} ->
          mark_failed_after_success_resolution_error(config.repo, run, context, reason)
      end
    end
  end

  def persist_execution_result(
        {:error, reason},
        config,
        definition,
        run,
        step_run_id,
        attempt_id,
        attempt_number,
        started_at
      ) do
    error = normalize_error(reason)
    duration = System.monotonic_time() - started_at

    with {:ok, _attempt} <- AttemptStore.fail_attempt(config.repo, attempt_id, error),
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
          handle_terminal_or_routed_failure(config, definition, run, error)
      end
    end
  end

  defp advance_after_success(config, run, :complete, output, _execution_opts) do
    context = Map.merge(run.context || %{}, output)
    finalize_success(config, run.id, context, :complete)
  end

  defp advance_after_success(config, run, next_step, output, execution_opts)
       when is_atom(next_step) do
    context = Map.merge(run.context || %{}, output)
    dispatch_opts = Keyword.take(execution_opts, [:schedule_in])
    finalize_success(config, run.id, context, {:next_step, next_step, dispatch_opts})
  end

  defp success_target(repo, definition, run) do
    if WorkflowDefinition.dependency_mode?(definition) do
      completed_steps = StepRunStore.completed_steps(repo, run.id)

      try do
        WorkflowDefinition.next_step_after_success(definition, run.current_step, completed_steps)
      rescue
        exception in ArgumentError ->
          if Exception.message(exception) == "workflow dependency graph must be acyclic" do
            {:error, {:invalid_dependency_graph, Exception.message(exception)}}
          else
            reraise exception, __STACKTRACE__
          end
      end
    else
      WorkflowDefinition.transition_target(definition, run.current_step, :ok)
    end
  end

  defp finalize_success(config, run_id, context, :complete) do
    with {:ok, latest_run} <- RunStore.get_run(config.repo, run_id) do
      case latest_run.status do
        :cancelling ->
          RunStore.transition_run(config.repo, run_id, :cancelled, %{
            context: context,
            current_step: nil,
            last_error: nil
          })
          |> normalize_run_transition_result()

        _other_status ->
          RunStore.transition_run(config.repo, run_id, :completed, %{
            context: context,
            current_step: nil,
            last_error: nil
          })
          |> normalize_run_transition_result()
      end
    end
  end

  defp finalize_success(config, run_id, context, {:next_step, next_step, dispatch_opts}) do
    with {:ok, latest_run} <- RunStore.get_run(config.repo, run_id) do
      case latest_run.status do
        :cancelling ->
          RunStore.transition_run(config.repo, run_id, :cancelled, %{
            context: context,
            current_step: nil,
            last_error: nil
          })
          |> normalize_run_transition_result()

        _other_status ->
          case RunStore.update_and_dispatch_run(
                 config.repo,
                 run_id,
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
                run_id,
                next_step,
                context,
                reason
              )
          end
      end
    end
  end

  defp handle_terminal_or_routed_failure(config, definition, run, error) do
    case WorkflowDefinition.transition_target(definition, run.current_step, :error) do
      {:ok, target} ->
        Logger.warning("workflow step failed; routing to error transition")
        advance_after_failure(config, run, target)

      {:error, {:unknown_transition, _from_step, :error}} ->
        Logger.error("workflow step failed")

        case RunStore.transition_run(config.repo, run.id, :failed, %{
               current_step: run.current_step,
               last_error: error
             }) do
          {:ok, _failed_run} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp advance_after_failure(config, run, :complete) do
    finalize_failure(config, run.id, :complete)
  end

  defp advance_after_failure(config, run, next_step) when is_atom(next_step) do
    finalize_failure(config, run.id, {:next_step, next_step})
  end

  defp finalize_failure(config, run_id, :complete) do
    with {:ok, latest_run} <- RunStore.get_run(config.repo, run_id) do
      case latest_run.status do
        :cancelling ->
          RunStore.transition_run(config.repo, run_id, :cancelled, %{
            current_step: nil,
            last_error: nil
          })
          |> normalize_run_transition_result()

        _other_status ->
          RunStore.transition_run(config.repo, run_id, :completed, %{
            current_step: nil,
            last_error: nil
          })
          |> normalize_run_transition_result()
      end
    end
  end

  defp finalize_failure(config, run_id, {:next_step, next_step}) do
    with {:ok, latest_run} <- RunStore.get_run(config.repo, run_id) do
      case latest_run.status do
        :cancelling ->
          RunStore.transition_run(config.repo, run_id, :cancelled, %{
            current_step: nil,
            last_error: nil
          })
          |> normalize_run_transition_result()

        _other_status ->
          case RunStore.update_and_dispatch_run(
                 config.repo,
                 run_id,
                 %{
                   current_step: next_step,
                   last_error: nil
                 },
                 fn updated_run -> Dispatcher.dispatch_run(config, updated_run, []) end
               ) do
            {:ok, _updated_run} ->
              :ok

            {:error, reason} ->
              mark_failed_after_error_branch_dispatch_error(
                config.repo,
                run_id,
                next_step,
                reason
              )
          end
      end
    end
  end

  defp normalize_run_transition_result({:ok, _run}), do: :ok
  defp normalize_run_transition_result({:error, reason}), do: {:error, reason}

  defp normalize_error(%{__struct__: module} = error) do
    details =
      error
      |> Map.from_struct()
      |> Map.get(:details, %{})
      |> SquidMesh.Runtime.StepExecutor.Input.normalize_map_keys()

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

  defp mark_failed_after_success_resolution_error(
         repo,
         run,
         context,
         {:no_runnable_step, pending_steps}
       ) do
    case RunStore.transition_run(repo, run.id, :failed, %{
           context: context,
           current_step: run.current_step,
           last_error: %{
             message: "workflow step completed but no runnable next step was found",
             failed_step: run.current_step,
             pending_steps: pending_steps
           }
         }) do
      {:ok, _failed_run} -> :ok
      {:error, transition_reason} -> {:error, transition_reason}
    end
  end

  defp mark_failed_after_success_resolution_error(repo, run, context, reason) do
    case RunStore.transition_run(repo, run.id, :failed, %{
           context: context,
           current_step: run.current_step,
           last_error: %{
             message: "workflow step completed but next step resolution failed",
             failed_step: run.current_step,
             cause: normalize_success_resolution_error(reason)
           }
         }) do
      {:ok, _failed_run} -> :ok
      {:error, transition_reason} -> {:error, transition_reason}
    end
  end

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

  defp mark_failed_after_error_branch_dispatch_error(repo, run_id, next_step, reason) do
    dispatch_error = %{
      message: "failed to dispatch workflow step",
      next_step: next_step,
      dispatch_reason: normalize_dispatch_cause(reason)
    }

    case RunStore.transition_run(repo, run_id, :failed, %{
           current_step: next_step,
           last_error: dispatch_error
         }) do
      {:ok, _failed_run} -> :ok
      {:error, transition_reason} -> {:error, transition_reason}
    end
  end

  defp normalize_success_resolution_error({:unknown_transition, from_step, outcome}) do
    %{from_step: from_step, outcome: outcome}
  end

  defp normalize_success_resolution_error({:invalid_dependency_graph, message}) do
    %{reason: :invalid_dependency_graph, message: message}
  end

  defp normalize_success_resolution_error(other), do: %{reason: inspect(other)}

  defp normalize_dispatch_cause({:dispatch_failed, reason}), do: normalize_dispatch_cause(reason)

  defp normalize_dispatch_cause(%{__struct__: _module} = error),
    do: %{message: Exception.message(error)}

  defp normalize_dispatch_cause(reason), do: reason

  defp retry_dispatch_opts(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    [schedule_in: ceil(delay_ms / 1_000)]
  end

  defp retry_dispatch_opts(_delay_ms), do: []
end
