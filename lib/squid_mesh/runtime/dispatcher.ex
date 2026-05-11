defmodule SquidMesh.Runtime.Dispatcher do
  @moduledoc """
  Enqueues durable workflow step execution.

  The workflow contract stays declarative while this module bridges runtime
  intent into Oban-backed execution jobs.
  """

  alias SquidMesh.Config
  alias SquidMesh.Observability
  alias SquidMesh.Run
  alias SquidMesh.Runtime.StepInput
  alias SquidMesh.StepRunStore
  alias SquidMesh.Workflow.Definition, as: WorkflowDefinition
  alias SquidMesh.Workers.StepWorker

  @type dispatch_error :: Ecto.Changeset.t() | term()
  @type dispatch_opts :: [schedule_in: pos_integer()]
  @type dispatch_target :: atom()
  @type dispatch_event :: {:run_dispatched, Run.t(), Oban.Job.t(), atom(), pos_integer() | nil}

  @spec dispatch_run(Config.t(), Run.t(), dispatch_opts()) ::
          {:ok, Oban.Job.t() | [Oban.Job.t()]} | {:error, dispatch_error()}
  def dispatch_run(config, run, opts \\ [])

  def dispatch_run(%Config{} = config, %Run{} = run, opts) do
    case dispatch_run_with_events(config, run, opts) do
      {:ok, jobs, events} ->
        emit_dispatch_events(events)
        {:ok, jobs}

      {:error, _reason} = error ->
        error
    end
  end

  @spec dispatch_run_with_events(Config.t(), Run.t(), dispatch_opts()) ::
          {:ok, Oban.Job.t() | [Oban.Job.t()], [dispatch_event()]}
          | {:error, dispatch_error()}
  def dispatch_run_with_events(config, run, opts \\ [])

  def dispatch_run_with_events(
        %Config{} = config,
        %Run{workflow: workflow, current_step: nil} = run,
        opts
      )
      when is_atom(workflow) do
    with {:ok, definition} <- WorkflowDefinition.load(workflow),
         true <- WorkflowDefinition.dependency_mode?(definition) || {:error, {:invalid_step, nil}} do
      dispatch_steps_with_events(
        config,
        run,
        WorkflowDefinition.entry_steps(definition),
        Keyword.put(opts, :schedule_pending, true)
      )
    end
  end

  def dispatch_run_with_events(%Config{} = config, %Run{current_step: current_step} = run, opts)
      when is_atom(current_step) do
    dispatch_steps_with_events(config, run, [current_step], opts)
  end

  def dispatch_run_with_events(%Config{}, %Run{current_step: current_step}, _opts) do
    {:error, {:invalid_step, current_step}}
  end

  @spec dispatch_steps(Config.t(), Run.t(), [dispatch_target()], keyword()) ::
          {:ok, Oban.Job.t() | [Oban.Job.t()]} | {:error, dispatch_error()}
  def dispatch_steps(%Config{} = config, %Run{} = run, steps, opts \\ []) when is_list(steps) do
    case dispatch_steps_with_events(config, run, steps, opts) do
      {:ok, jobs, events} ->
        emit_dispatch_events(events)
        {:ok, jobs}

      {:error, _reason} = error ->
        error
    end
  end

  @spec dispatch_steps_with_events(Config.t(), Run.t(), [dispatch_target()], keyword()) ::
          {:ok, Oban.Job.t() | [Oban.Job.t()], [dispatch_event()]}
          | {:error, dispatch_error()}
  def dispatch_steps_with_events(%Config{} = config, %Run{} = run, steps, opts \\ [])
      when is_list(steps) do
    schedule_in = Keyword.get(opts, :schedule_in)
    schedule_pending? = Keyword.get(opts, :schedule_pending, false)

    job_opts =
      [queue: config.execution_queue]
      |> maybe_put_schedule_in(schedule_in)

    with {:ok, jobs} <-
           dispatch_steps_transaction(config, run, steps, job_opts, schedule_pending?) do
      events = Enum.map(jobs, &run_dispatched_event(run, &1, config.execution_queue, schedule_in))

      case jobs do
        [job] -> {:ok, job, events}
        multiple_jobs -> {:ok, multiple_jobs, events}
      end
    end
  end

  defp emit_dispatch_events(events) do
    Enum.each(events, fn {:run_dispatched, run, job, queue, schedule_in} ->
      Observability.emit_run_dispatched(run, job, queue, schedule_in)
    end)
  end

  defp run_dispatched_event(run, job, queue, schedule_in) do
    {:run_dispatched, run, job, queue, schedule_in}
  end

  defp dispatch_steps_transaction(config, run, steps, job_opts, schedule_pending?) do
    if config.repo.in_transaction?() do
      dispatch_steps_without_transaction(config, run, steps, job_opts, schedule_pending?)
    else
      # Pending step rows and Oban jobs are one dispatch unit. Direct callers
      # need the same rollback behavior that run progression already provides.
      case config.repo.transaction(fn ->
             case dispatch_steps_without_transaction(
                    config,
                    run,
                    steps,
                    job_opts,
                    schedule_pending?
                  ) do
               {:ok, jobs} -> jobs
               {:error, reason} -> config.repo.rollback(reason)
             end
           end) do
        {:ok, jobs} -> {:ok, jobs}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp dispatch_steps_without_transaction(config, run, steps, job_opts, schedule_pending?) do
    with {:ok, steps_to_dispatch} <- steps_to_dispatch(config, run, steps, schedule_pending?) do
      case insert_step_jobs(config, run, steps_to_dispatch, job_opts) do
        {:ok, jobs} ->
          {:ok, jobs}

        {:error, _reason} = error ->
          cleanup_scheduled_steps(config, run, steps_to_dispatch, schedule_pending?)
          error
      end
    end
  end

  defp cleanup_scheduled_steps(config, run, steps, true) do
    StepRunStore.delete_pending_steps(config.repo, run.id, steps)
  end

  defp cleanup_scheduled_steps(_config, _run, _steps, false), do: :ok

  defp steps_to_dispatch(config, run, steps, true) do
    steps
    |> Enum.uniq()
    |> build_scheduled_step_inputs(config, run)
    |> case do
      {:ok, step_inputs} -> StepRunStore.schedule_steps(config.repo, run.id, step_inputs)
      {:error, _reason} = error -> error
    end
  end

  defp steps_to_dispatch(_config, _run, steps, false), do: {:ok, Enum.uniq(steps)}

  defp build_scheduled_step_inputs(steps, config, run) do
    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, step_inputs} ->
      case scheduled_step_input(config, run, step) do
        {:ok, input, recovery} -> {:cont, {:ok, [{step, input, recovery} | step_inputs]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, step_inputs} -> {:ok, Enum.reverse(step_inputs)}
      {:error, _reason} = error -> error
    end
  end

  defp insert_step_jobs(_config, _run, [], _job_opts), do: {:ok, []}

  defp insert_step_jobs(config, %Run{id: run_id}, steps, job_opts) do
    changesets =
      Enum.map(steps, fn step ->
        StepWorker.new(%{run_id: run_id, step: step}, job_opts)
      end)

    with :ok <- validate_job_changesets(changesets) do
      do_insert_step_jobs(config, changesets)
    end
  end

  defp validate_job_changesets(changesets) do
    case Enum.find(changesets, &(not &1.valid?)) do
      nil -> :ok
      invalid_changeset -> {:error, invalid_changeset}
    end
  end

  defp do_insert_step_jobs(config, changesets) do
    try do
      config.execution_name
      |> Oban.insert_all(changesets)
      |> normalize_insert_all_result()
    rescue
      exception -> {:error, exception}
    end
  end

  defp normalize_insert_all_result({:ok, jobs}) when is_list(jobs), do: {:ok, jobs}
  defp normalize_insert_all_result(jobs) when is_list(jobs), do: {:ok, jobs}
  defp normalize_insert_all_result({:error, reason}), do: {:error, reason}
  defp normalize_insert_all_result(other), do: {:error, {:unexpected_insert_all_result, other}}

  defp maybe_put_schedule_in(opts, schedule_in)
       when is_integer(schedule_in) and schedule_in > 0 do
    Keyword.put(opts, :schedule_in, schedule_in)
  end

  defp maybe_put_schedule_in(opts, _schedule_in), do: opts

  defp scheduled_step_input(%Config{repo: repo}, %Run{workflow: workflow} = run, step_name)
       when is_atom(workflow) do
    with {:ok, definition} <- WorkflowDefinition.load(workflow),
         {:ok, input_mapping} <- WorkflowDefinition.step_input_mapping(definition, step_name),
         {:ok, recovery} <- WorkflowDefinition.step_recovery_policy(definition, step_name) do
      {:ok, build_scheduled_step_input(definition, repo, run, input_mapping), recovery}
    end
  end

  defp scheduled_step_input(_config, %Run{} = run, _step_name),
    do: {:ok, StepInput.build_step_input(run), nil}

  defp build_scheduled_step_input(definition, repo, run, input_mapping) do
    if WorkflowDefinition.dependency_mode?(definition) do
      StepInput.build_dependency_step_input(repo, run, input_mapping)
    else
      StepInput.build_step_input(run, input_mapping)
    end
  end
end
