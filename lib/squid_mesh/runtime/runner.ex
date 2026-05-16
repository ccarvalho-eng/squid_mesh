defmodule SquidMesh.Runtime.Runner do
  @moduledoc """
  Backend-neutral runtime entrypoints for host executors.

  Executor jobs should call these functions when queued work is delivered.
  """

  require Logger

  alias SquidMesh.Observability
  alias SquidMesh.Runtime.ScheduleMetadata
  alias SquidMesh.Runtime.StepExecutor
  alias SquidMesh.Workflow.Definition, as: WorkflowDefinition

  @spec perform(map(), keyword()) :: :ok | {:error, term()}
  def perform(args, overrides \\ [])

  def perform(%{"kind" => "step", "run_id" => run_id, "step" => step}, overrides)
      when is_binary(run_id) and is_binary(step) do
    execute_step(run_id, step, overrides)
  end

  def perform(%{"kind" => "compensation", "run_id" => run_id}, overrides)
      when is_binary(run_id) do
    execute_compensation(run_id, overrides)
  end

  def perform(%{"kind" => "cron", "workflow" => workflow, "trigger" => trigger} = args, overrides)
      when is_binary(workflow) and is_binary(trigger) do
    start_cron_trigger(workflow, trigger, args, overrides)
  end

  def perform(args, _overrides) do
    {:error, {:invalid_executor_payload, args}}
  end

  @spec execute_step(Ecto.UUID.t(), atom() | String.t(), keyword()) :: :ok | {:error, term()}
  def execute_step(run_id, step, overrides \\ []) when is_binary(run_id) do
    Observability.with_run_metadata(run_stub(run_id, step), fn ->
      try do
        case StepExecutor.execute(run_id, step, overrides) do
          :ok ->
            :ok

          {:error, reason} = error ->
            Logger.error("step execution failed: #{inspect(reason)}")
            error
        end
      rescue
        exception ->
          Logger.error("""
          unexpected step execution exception: #{Exception.format(:error, exception, __STACKTRACE__)}
          """)

          {:error, {:exception, Exception.message(exception)}}
      end
    end)
  end

  @spec execute_compensation(Ecto.UUID.t(), keyword()) :: :ok | {:error, term()}
  def execute_compensation(run_id, overrides \\ []) when is_binary(run_id) do
    Observability.with_run_metadata(run_stub(run_id, nil), fn ->
      try do
        case StepExecutor.compensate(run_id, overrides) do
          :ok ->
            :ok

          {:error, reason} = error ->
            Logger.error("compensation execution failed: #{inspect(reason)}")
            error
        end
      rescue
        exception ->
          Logger.error("""
          unexpected compensation exception: #{Exception.format(:error, exception, __STACKTRACE__)}
          """)

          {:error, {:exception, Exception.message(exception)}}
      end
    end)
  end

  @spec start_cron_trigger(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def start_cron_trigger(workflow_name, trigger_name, overrides \\ [])
      when is_binary(workflow_name) and is_binary(trigger_name) do
    start_cron_trigger(workflow_name, trigger_name, %{}, overrides)
  end

  @spec start_cron_trigger(String.t(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def start_cron_trigger(workflow_name, trigger_name, signal_payload, overrides)
      when is_binary(workflow_name) and is_binary(trigger_name) and is_map(signal_payload) and
             is_list(overrides) do
    with {:ok, workflow, definition} <- WorkflowDefinition.load_serialized(workflow_name),
         trigger when is_atom(trigger) <-
           WorkflowDefinition.deserialize_trigger(definition, trigger_name),
         {:ok, trigger_definition} <- WorkflowDefinition.trigger(definition, trigger),
         {:ok, _run} <-
           SquidMesh.start_run(
             workflow,
             trigger,
             %{},
             scheduled_start_overrides(trigger_definition, signal_payload, overrides)
           ) do
      :ok
    else
      {:error, reason} ->
        {:error, reason}

      invalid_trigger ->
        {:error, {:invalid_trigger, invalid_trigger}}
    end
  end

  defp run_stub(run_id, step) do
    %SquidMesh.Run{id: run_id, workflow: nil, trigger: nil, status: nil, current_step: step}
  end

  defp scheduled_start_overrides(trigger_definition, signal_payload, overrides) do
    schedule_context = ScheduleMetadata.cron_context(trigger_definition, signal_payload)
    existing_context = existing_context(overrides)

    Keyword.put(overrides, :context, Map.merge(existing_context, schedule_context))
  end

  defp existing_context(overrides) do
    case Keyword.get(overrides, :context, %{}) do
      %{} = context -> context
      _other -> %{}
    end
  end
end
