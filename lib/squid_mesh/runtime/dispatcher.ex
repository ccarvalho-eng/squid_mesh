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

  @spec dispatch_run(Config.t(), Run.t(), dispatch_opts()) ::
          {:ok, Oban.Job.t() | [Oban.Job.t()]} | {:error, dispatch_error()}
  def dispatch_run(config, run, opts \\ [])

  def dispatch_run(%Config{} = config, %Run{workflow: workflow, current_step: nil} = run, opts)
      when is_atom(workflow) do
    with {:ok, definition} <- WorkflowDefinition.load(workflow),
         true <- WorkflowDefinition.dependency_mode?(definition) || {:error, {:invalid_step, nil}} do
      dispatch_steps(
        config,
        run,
        WorkflowDefinition.entry_steps(definition),
        Keyword.put(opts, :schedule_pending, true)
      )
    end
  end

  def dispatch_run(%Config{} = config, %Run{current_step: current_step} = run, opts)
      when is_atom(current_step) do
    dispatch_steps(config, run, [current_step], opts)
  end

  def dispatch_run(%Config{}, %Run{current_step: current_step}, _opts) do
    {:error, {:invalid_step, current_step}}
  end

  @spec dispatch_steps(Config.t(), Run.t(), [dispatch_target()], keyword()) ::
          {:ok, Oban.Job.t() | [Oban.Job.t()]} | {:error, dispatch_error()}
  def dispatch_steps(%Config{} = config, %Run{} = run, steps, opts \\ []) when is_list(steps) do
    schedule_in = Keyword.get(opts, :schedule_in)
    schedule_pending? = Keyword.get(opts, :schedule_pending, false)

    job_opts =
      [queue: config.execution_queue]
      |> maybe_put_schedule_in(schedule_in)

    with {:ok, jobs} <-
           do_dispatch_steps(config, run, steps, job_opts, schedule_pending?, schedule_in) do
      case jobs do
        [job] -> {:ok, job}
        multiple_jobs -> {:ok, multiple_jobs}
      end
    end
  end

  defp do_dispatch_steps(config, run, steps, job_opts, schedule_pending?, schedule_in) do
    steps
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn step, {:ok, jobs} ->
      with :ok <- maybe_schedule_pending_step(config, run, step, schedule_pending?),
           {:ok, job} <- insert_step_job(config, run, step, job_opts, schedule_in) do
        {:cont, {:ok, [job | jobs]}}
      else
        {:skip, _step_run} ->
          {:cont, {:ok, jobs}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, jobs} -> {:ok, Enum.reverse(jobs)}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_schedule_pending_step(_config, _run, _step, false), do: :ok

  defp maybe_schedule_pending_step(config, run, step, true) do
    with {:ok, input} <- scheduled_step_input(config, run, step) do
      case StepRunStore.schedule_step(config.repo, run.id, step, input) do
        {:ok, _step_run, :schedule} -> :ok
        {:ok, step_run, :skip} -> {:skip, step_run}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp insert_step_job(config, %Run{id: run_id} = run, step, job_opts, schedule_in) do
    try do
      %{run_id: run_id, step: step}
      |> StepWorker.new(job_opts)
      |> then(&Oban.insert(config.execution_name, &1))
      |> case do
        {:ok, job} = ok ->
          Observability.emit_run_dispatched(run, job, config.execution_queue, schedule_in)
          ok

        {:error, _reason} = error ->
          error
      end
    rescue
      exception -> {:error, exception}
    end
  end

  defp maybe_put_schedule_in(opts, schedule_in)
       when is_integer(schedule_in) and schedule_in > 0 do
    Keyword.put(opts, :schedule_in, schedule_in)
  end

  defp maybe_put_schedule_in(opts, _schedule_in), do: opts

  defp scheduled_step_input(%Config{repo: repo}, %Run{workflow: workflow} = run, step_name)
       when is_atom(workflow) do
    with {:ok, definition} <- WorkflowDefinition.load(workflow),
         {:ok, input_mapping} <- WorkflowDefinition.step_input_mapping(definition, step_name) do
      {:ok, build_scheduled_step_input(definition, repo, run, input_mapping)}
    end
  end

  defp scheduled_step_input(_config, %Run{} = run, _step_name),
    do: {:ok, StepInput.build_step_input(run)}

  defp build_scheduled_step_input(definition, repo, run, input_mapping) do
    if WorkflowDefinition.dependency_mode?(definition) do
      StepInput.build_dependency_step_input(repo, run, input_mapping)
    else
      StepInput.build_step_input(run, input_mapping)
    end
  end
end
