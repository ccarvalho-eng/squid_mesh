defmodule SquidMesh.Observability do
  @moduledoc false

  require Logger

  alias SquidMesh.Run

  @prefix [:squid_mesh]

  @spec emit_run_created(Run.t()) :: :ok
  def emit_run_created(%Run{} = run) do
    emit([:run, :created], %{system_time: System.system_time()}, run_metadata(run))
  end

  @spec emit_run_replayed(Run.t()) :: :ok
  def emit_run_replayed(%Run{} = run) do
    emit([:run, :replayed], %{system_time: System.system_time()}, run_metadata(run))
  end

  @spec emit_run_dispatched(Run.t(), Oban.Job.t(), atom(), pos_integer() | nil) :: :ok
  def emit_run_dispatched(%Run{} = run, %Oban.Job{} = job, queue, schedule_in) do
    emit(
      [:run, :dispatched],
      %{system_time: System.system_time()},
      run_metadata(run)
      |> Map.merge(%{
        job_id: job.id,
        queue: queue,
        schedule_in: schedule_in
      })
    )
  end

  @spec emit_run_transition(Run.t(), Run.status(), Run.status()) :: :ok
  def emit_run_transition(%Run{} = run, from_status, to_status) do
    emit(
      [:run, :transition],
      %{system_time: System.system_time()},
      run_metadata(run)
      |> Map.merge(%{
        from_status: from_status,
        to_status: to_status
      })
    )
  end

  @spec emit_step_started(Run.t(), atom(), pos_integer()) :: :ok
  def emit_step_started(%Run{} = run, step, attempt) do
    emit(
      [:step, :started],
      %{system_time: System.system_time()},
      step_metadata(run, step, attempt)
    )
  end

  @spec emit_step_skipped(Run.t(), atom(), String.t()) :: :ok
  def emit_step_skipped(%Run{} = run, step, reason) do
    emit(
      [:step, :skipped],
      %{system_time: System.system_time()},
      step_metadata(run, step, nil)
      |> Map.put(:reason, reason)
    )
  end

  @spec emit_step_completed(Run.t(), atom(), pos_integer(), non_neg_integer()) :: :ok
  def emit_step_completed(%Run{} = run, step, attempt, duration_native) do
    emit(
      [:step, :completed],
      %{duration: duration_native, system_time: System.system_time()},
      step_metadata(run, step, attempt)
    )
  end

  @spec emit_step_failed(Run.t(), atom(), pos_integer(), non_neg_integer(), map()) :: :ok
  def emit_step_failed(%Run{} = run, step, attempt, duration_native, error) when is_map(error) do
    emit(
      [:step, :failed],
      %{duration: duration_native, system_time: System.system_time()},
      step_metadata(run, step, attempt)
      |> Map.put(:error, error)
    )
  end

  @spec emit_step_retry_scheduled(Run.t(), atom(), pos_integer(), non_neg_integer()) :: :ok
  def emit_step_retry_scheduled(%Run{} = run, step, attempt, delay_ms) do
    emit(
      [:step, :retry_scheduled],
      %{delay_ms: delay_ms, system_time: System.system_time()},
      step_metadata(run, step, attempt)
    )
  end

  @spec with_run_metadata(Run.t(), (-> result)) :: result when result: var
  def with_run_metadata(%Run{} = run, fun) when is_function(fun, 0) do
    with_logger_metadata(run_metadata(run), fun)
  end

  @spec with_step_metadata(Run.t(), atom(), pos_integer() | nil, (-> result)) :: result
        when result: var
  def with_step_metadata(%Run{} = run, step, attempt, fun) when is_function(fun, 0) do
    with_logger_metadata(step_metadata(run, step, attempt), fun)
  end

  @spec run_metadata(Run.t()) :: map()
  defp run_metadata(%Run{} = run) do
    %{
      run_id: run.id,
      workflow: run.workflow,
      trigger: run.trigger,
      status: run.status,
      current_step: run.current_step
    }
  end

  @spec step_metadata(Run.t(), atom(), pos_integer() | nil) :: map()
  defp step_metadata(%Run{} = run, step, attempt) do
    run_metadata(run)
    |> Map.put(:step, step)
    |> Map.put(:attempt, attempt)
  end

  @spec with_logger_metadata(map(), (-> result)) :: result when result: var
  defp with_logger_metadata(metadata, fun) do
    previous_metadata = Logger.metadata()

    Logger.metadata(Enum.to_list(metadata))

    try do
      fun.()
    after
      Logger.reset_metadata(previous_metadata)
    end
  end

  @spec emit([atom()], map(), map()) :: :ok
  defp emit(event, measurements, metadata) do
    :telemetry.execute(@prefix ++ event, measurements, metadata)
  end
end
