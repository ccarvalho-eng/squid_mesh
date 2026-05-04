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
          atom(),
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
        step_name,
        config,
        definition,
        run,
        step_run_id,
        attempt_id,
        attempt_number,
        started_at
      ) do
    duration = System.monotonic_time() - started_at

    with {:ok, _attempt} <- AttemptStore.complete_attempt(config.repo, attempt_id),
         {:ok, _step_run} <- StepRunStore.complete_step(config.repo, step_run_id, output) do
      Observability.emit_step_completed(run, step_name, attempt_number, duration)

      case success_resolution(config.repo, definition, run, step_name) do
        {:ok, latest_run, target} ->
          advance_after_success(
            config,
            definition,
            latest_run,
            step_name,
            target,
            output,
            execution_opts
          )

        :already_terminal ->
          :ok

        {:retrying, _latest_run} ->
          RunStore.progress_run_with(
            config.repo,
            run.id,
            fn current_run ->
              %{context: merged_context(current_run, output)}
            end,
            :update
          )
          |> normalize_progress_result()

        {:error, latest_run, reason} ->
          mark_failed_after_success_resolution_error(
            config.repo,
            run,
            step_name,
            merged_context(latest_run, output),
            reason
          )
      end
    end
  end

  def persist_execution_result(
        {:error, reason},
        step_name,
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
      Observability.emit_step_failed(run, step_name, attempt_number, duration, error)

      case RetryPolicy.resolve(run.workflow, step_name, attempt_number) do
        {:retry, _next_attempt, delay_ms} ->
          Logger.warning("workflow step failed; scheduling retry")
          Observability.emit_step_retry_scheduled(run, step_name, attempt_number, delay_ms)

          dispatch_opts = retry_dispatch_opts(delay_ms)

          case RunStore.progress_run_with(
                 config.repo,
                 run.id,
                 fn _current_run ->
                   %{
                     current_step: step_name,
                     last_error: error
                   }
                 end,
                 {:transition_or_dispatch, :retrying,
                  fn retried_run ->
                    Dispatcher.dispatch_run(config, retried_run, dispatch_opts)
                  end}
               ) do
            {:ok, _result} ->
              :ok

            {:error, reason} ->
              mark_failed_after_retry_dispatch_error(config.repo, run, step_name, error, reason)
          end

        _no_retry ->
          handle_terminal_or_routed_failure(config, definition, run, step_name, error)
      end
    end
  end

  defp advance_after_success(
         config,
         _definition,
         run,
         _step_name,
         :complete,
         output,
         _execution_opts
       ) do
    finalize_progress(
      config,
      run.id,
      fn current_run ->
        %{
          context: merged_context(current_run, output),
          current_step: nil,
          last_error: nil
        }
      end,
      :complete
    )
  end

  defp advance_after_success(
         config,
         definition,
         run,
         _step_name,
         {:dispatch, next_steps},
         output,
         execution_opts
       )
       when is_list(next_steps) do
    dispatch_opts = Keyword.take(execution_opts, [:schedule_in])

    finalize_progress(
      config,
      run.id,
      fn current_run -> success_attrs(definition, current_run, output, nil) end,
      {:dispatch_steps, next_steps, dispatch_opts,
       fn reason ->
         attrs = success_attrs(definition, run, output, nil)

         dispatch_error = %{
           message: "failed to dispatch workflow step",
           next_steps: next_steps,
           dispatch_reason: normalize_dispatch_cause(reason)
         }

         mark_failed_after_dispatch_error(config.repo, run.id, attrs, dispatch_error)
       end}
    )
  end

  defp advance_after_success(
         config,
         definition,
         run,
         _step_name,
         {:wait, _phase_steps},
         output,
         _execution_opts
       ) do
    RunStore.progress_run_with(
      config.repo,
      run.id,
      fn current_run -> success_attrs(definition, current_run, output, nil) end,
      :update
    )
    |> normalize_progress_result()
  end

  defp advance_after_success(
         config,
         definition,
         run,
         _step_name,
         next_step,
         output,
         execution_opts
       )
       when is_atom(next_step) do
    dispatch_opts = Keyword.take(execution_opts, [:schedule_in])

    finalize_progress(
      config,
      run.id,
      fn current_run -> success_attrs(definition, current_run, output, next_step) end,
      {:next_step, next_step, dispatch_opts,
       fn reason ->
         attrs = success_attrs(definition, run, output, next_step)

         dispatch_error = %{
           message: "failed to dispatch workflow step",
           next_step: next_step,
           cause: normalize_dispatch_cause(reason)
         }

         mark_failed_after_dispatch_error(config.repo, run.id, attrs, dispatch_error)
       end}
    )
  end

  defp success_resolution(repo, definition, run, step_name) do
    with {:ok, latest_run} <- RunStore.get_run(repo, run.id) do
      cond do
        latest_run.status in [:failed, :completed, :cancelled] ->
          :already_terminal

        latest_run.status == :retrying and WorkflowDefinition.dependency_mode?(definition) ->
          {:retrying, latest_run}

        WorkflowDefinition.dependency_mode?(definition) ->
          resolve_dependency_success(repo, definition, latest_run)

        true ->
          case WorkflowDefinition.transition_target(definition, step_name, :ok) do
            {:ok, target} -> {:ok, latest_run, target}
            {:error, reason} -> {:error, latest_run, reason}
          end
      end
    end
  end

  defp finalize_progress(config, run_id, attrs_fun, :complete) do
    attrs_fun = normalize_attrs_fun(attrs_fun)

    RunStore.progress_run_with(config.repo, run_id, attrs_fun, {:transition, :completed})
    |> normalize_progress_result()
  end

  defp finalize_progress(
         config,
         run_id,
         attrs_fun,
         {:dispatch_steps, next_steps, dispatch_opts, dispatch_error_handler}
       ) do
    attrs_fun = normalize_attrs_fun(attrs_fun)

    case RunStore.progress_run_with(
           config.repo,
           run_id,
           attrs_fun,
           {:dispatch,
            fn updated_run ->
              Dispatcher.dispatch_steps(
                config,
                updated_run,
                next_steps,
                Keyword.put(dispatch_opts, :schedule_pending, true)
              )
            end}
         ) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        dispatch_error_handler.(reason)
    end
  end

  defp finalize_progress(
         config,
         run_id,
         attrs_fun,
         {:next_step, _next_step, dispatch_opts, dispatch_error_handler}
       ) do
    attrs_fun = normalize_attrs_fun(attrs_fun)

    case RunStore.progress_run_with(
           config.repo,
           run_id,
           attrs_fun,
           {:dispatch,
            fn updated_run -> Dispatcher.dispatch_run(config, updated_run, dispatch_opts) end}
         ) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        dispatch_error_handler.(reason)
    end
  end

  defp handle_terminal_or_routed_failure(config, definition, run, step_name, error) do
    if WorkflowDefinition.dependency_mode?(definition) do
      Logger.error("workflow step failed")

      case RunStore.progress_run_with(
             config.repo,
             run.id,
             fn _current_run ->
               %{
                 current_step: step_name,
                 last_error: error
               }
             end,
             {:transition, :failed}
           ) do
        {:ok, _result} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      case WorkflowDefinition.transition_target(definition, step_name, :error) do
        {:ok, target} ->
          Logger.warning("workflow step failed; routing to error transition")
          advance_after_failure(config, run, target)

        {:error, {:unknown_transition, _from_step, :error}} ->
          Logger.error("workflow step failed")

          case RunStore.progress_run_with(
                 config.repo,
                 run.id,
                 fn _current_run ->
                   %{
                     current_step: step_name,
                     last_error: error
                   }
                 end,
                 {:transition, :failed}
               ) do
            {:ok, _result} ->
              :ok

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp advance_after_failure(config, run, :complete) do
    finalize_progress(config, run.id, %{current_step: nil, last_error: nil}, :complete)
  end

  defp advance_after_failure(config, run, next_step) when is_atom(next_step) do
    attrs = %{current_step: next_step, last_error: nil}

    finalize_progress(
      config,
      run.id,
      attrs,
      {:next_step, next_step, [],
       fn reason ->
         dispatch_error = %{
           message: "failed to dispatch workflow step",
           next_step: next_step,
           dispatch_reason: normalize_dispatch_cause(reason)
         }

         mark_failed_after_dispatch_error(config.repo, run.id, attrs, dispatch_error)
       end}
    )
  end

  defp normalize_progress_result({:ok, _result}), do: :ok
  defp normalize_progress_result({:error, reason}), do: {:error, reason}

  defp normalize_error(%{__struct__: module} = error) do
    details =
      error
      |> Map.from_struct()
      |> Map.get(:details, %{})
      |> SquidMesh.Runtime.StepInput.normalize_map_keys()

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
         step_name,
         context,
         {:no_runnable_step, pending_steps}
       ) do
    case RunStore.transition_run(repo, run.id, :failed, %{
           context: context,
           current_step: step_name,
           last_error: %{
             message: "workflow step completed but no runnable next step was found",
             failed_step: step_name,
             pending_steps: pending_steps
           }
         }) do
      {:ok, _failed_run} -> :ok
      {:error, transition_reason} -> {:error, transition_reason}
    end
  end

  defp mark_failed_after_success_resolution_error(repo, run, step_name, context, reason) do
    case RunStore.transition_run(repo, run.id, :failed, %{
           context: context,
           current_step: step_name,
           last_error: %{
             message: "workflow step completed but next step resolution failed",
             failed_step: step_name,
             cause: normalize_success_resolution_error(reason)
           }
         }) do
      {:ok, _failed_run} -> :ok
      {:error, transition_reason} -> {:error, transition_reason}
    end
  end

  defp mark_failed_after_retry_dispatch_error(repo, run, step_name, step_error, reason) do
    dispatch_error = %{
      message: "failed to dispatch workflow step",
      failed_step: step_name,
      cause: step_error,
      dispatch_reason: normalize_dispatch_cause(reason)
    }

    case RunStore.transition_run(repo, run.id, :failed, %{
           current_step: step_name,
           last_error: dispatch_error
         }) do
      {:ok, _failed_run} -> :ok
      {:error, transition_reason} -> {:error, transition_reason}
    end
  end

  defp mark_failed_after_dispatch_error(repo, run_id, attrs, dispatch_error) do
    case RunStore.transition_run(
           repo,
           run_id,
           :failed,
           attrs
           |> Map.take([:context, :current_step])
           |> Map.put(:last_error, dispatch_error)
         ) do
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

  defp resolve_dependency_success(repo, definition, latest_run) do
    step_statuses = StepRunStore.step_statuses(repo, latest_run.id)

    try do
      case WorkflowDefinition.dependency_progress(definition, step_statuses) do
        :complete -> {:ok, latest_run, :complete}
        {:dispatch, steps} -> {:ok, latest_run, {:dispatch, steps}}
        {:wait, phase_steps} -> {:ok, latest_run, {:wait, phase_steps}}
        {:error, reason} -> {:error, latest_run, reason}
      end
    rescue
      exception in ArgumentError ->
        if Exception.message(exception) == "workflow dependency graph must be acyclic" do
          {:error, latest_run, {:invalid_dependency_graph, Exception.message(exception)}}
        else
          reraise exception, __STACKTRACE__
        end
    end
  end

  defp success_attrs(definition, run, output, next_step) do
    %{}
    |> Map.put(:context, merged_context(run, output))
    |> Map.put(:current_step, success_current_step(definition, next_step))
    |> Map.put(:last_error, nil)
  end

  defp success_current_step(definition, next_step) do
    if WorkflowDefinition.dependency_mode?(definition), do: nil, else: next_step
  end

  defp merged_context(run, output) do
    Map.merge(run.context || %{}, output)
  end

  defp normalize_attrs_fun(attrs_fun) when is_function(attrs_fun, 1), do: attrs_fun
  defp normalize_attrs_fun(attrs) when is_map(attrs), do: fn _run -> attrs end
end
