defmodule SquidMesh.RunStore.Serialization do
  @moduledoc """
  Read-side serialization and hydration helpers for workflow runs.

  `SquidMesh.RunStore` remains the public boundary. This module keeps the
  translation between persistence records and public structs in one place so
  command code can stay focused on lifecycle transitions.
  """

  import Ecto.Query

  alias SquidMesh.Persistence.StepAttempt, as: StepAttemptRecord
  alias SquidMesh.Persistence.Run, as: RunRecord
  alias SquidMesh.Persistence.StepRun, as: StepRunRecord
  alias SquidMesh.Run
  alias SquidMesh.StepAttempt
  alias SquidMesh.StepRun
  alias SquidMesh.Workflow.Definition, as: WorkflowDefinition

  @type list_filter ::
          {:workflow, module()} | {:status, Run.status()} | {:limit, pos_integer()}
  @type list_filters :: [list_filter()]

  @spec to_public_run(RunRecord.t()) :: Run.t()
  def to_public_run(run) do
    {workflow, definition} = deserialize_workflow(run.workflow)

    %Run{
      id: run.id,
      workflow: workflow,
      trigger: WorkflowDefinition.deserialize_trigger(definition, run.trigger),
      status: deserialize_status(run.status),
      payload: WorkflowDefinition.deserialize_payload(definition, run.input || %{}),
      context: deserialize_map(run.context || %{}),
      current_step: deserialize_step(definition, run.current_step),
      last_error: deserialize_run_error(definition, run.last_error),
      step_runs: to_public_step_runs(run, definition),
      replayed_from_run_id: run.replayed_from_run_id,
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end

  @spec serialize_filters(list_filters()) :: keyword()
  def serialize_filters(filters) do
    filters
    |> Enum.map(fn
      {:workflow, workflow} -> {:workflow, WorkflowDefinition.serialize_workflow(workflow)}
      {:status, status} -> {:status, serialize_status(status)}
      {:limit, limit} -> {:limit, limit}
    end)
  end

  @spec serialize_status(Run.status()) :: String.t()
  def serialize_status(status) when is_atom(status), do: Atom.to_string(status)

  @spec maybe_preload_history(Ecto.Queryable.t(), boolean()) :: Ecto.Query.t()
  def maybe_preload_history(query, true) do
    preload(query, [run], step_runs: ^step_runs_preload_query())
  end

  def maybe_preload_history(query, false), do: query

  @spec deserialize_status(String.t()) :: Run.status()
  def deserialize_status("pending"), do: :pending
  def deserialize_status("running"), do: :running
  def deserialize_status("retrying"), do: :retrying
  def deserialize_status("failed"), do: :failed
  def deserialize_status("completed"), do: :completed
  def deserialize_status("cancelling"), do: :cancelling
  def deserialize_status("cancelled"), do: :cancelled

  @spec deserialize_map(map() | nil) :: map() | nil
  def deserialize_map(nil), do: nil

  def deserialize_map(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        {deserialize_key(key), deserialize_value(value)}

      {key, value} ->
        {key, deserialize_value(value)}
    end)
  end

  @spec deserialize_step(WorkflowDefinition.t() | nil, String.t() | nil) ::
          atom() | String.t() | nil
  def deserialize_step(nil, step_name), do: step_name

  def deserialize_step(definition, step_name) do
    WorkflowDefinition.deserialize_step(definition, step_name)
  end

  @spec deserialize_workflow(String.t()) :: {module() | String.t(), WorkflowDefinition.t() | nil}
  def deserialize_workflow(workflow_name) do
    case WorkflowDefinition.load_serialized(workflow_name) do
      {:ok, workflow, definition} -> {workflow, definition}
      {:error, _reason} -> {workflow_name, nil}
    end
  end

  @spec deserialize_run_error(WorkflowDefinition.t() | nil, map() | nil) :: map() | nil
  def deserialize_run_error(_definition, nil), do: nil

  def deserialize_run_error(definition, error) when is_map(error) do
    error
    |> deserialize_map()
    |> maybe_update_error_step(:next_step, definition)
    |> maybe_update_error_step(:failed_step, definition)
    |> maybe_update_error_steps(:pending_steps, definition)
  end

  defp to_public_step_runs(%RunRecord{step_runs: %Ecto.Association.NotLoaded{}}, _definition),
    do: nil

  defp to_public_step_runs(%RunRecord{step_runs: step_runs}, definition)
       when is_list(step_runs) do
    Enum.map(step_runs, &to_public_step_run(&1, definition))
  end

  defp to_public_step_run(step_run, definition) do
    %StepRun{
      id: step_run.id,
      step: WorkflowDefinition.deserialize_step(definition, step_run.step),
      status: deserialize_step_status(step_run.status),
      input: deserialize_map(step_run.input || %{}),
      output: deserialize_map(step_run.output),
      last_error: deserialize_map(step_run.last_error),
      attempts: to_public_attempts(step_run),
      inserted_at: step_run.inserted_at,
      updated_at: step_run.updated_at
    }
  end

  defp to_public_attempts(%StepRunRecord{attempts: %Ecto.Association.NotLoaded{}}), do: []

  defp to_public_attempts(%StepRunRecord{attempts: attempts}) when is_list(attempts) do
    Enum.map(attempts, fn attempt ->
      %StepAttempt{
        id: attempt.id,
        attempt_number: attempt.attempt_number,
        status: deserialize_attempt_status(attempt.status),
        error: deserialize_map(attempt.error),
        inserted_at: attempt.inserted_at,
        updated_at: attempt.updated_at
      }
    end)
  end

  defp deserialize_step_status("pending"), do: :pending
  defp deserialize_step_status("running"), do: :running
  defp deserialize_step_status("completed"), do: :completed
  defp deserialize_step_status("failed"), do: :failed

  defp deserialize_attempt_status("running"), do: :running
  defp deserialize_attempt_status("completed"), do: :completed
  defp deserialize_attempt_status("failed"), do: :failed

  defp step_runs_preload_query do
    from(step_run in StepRunRecord,
      order_by: [asc: step_run.inserted_at, asc: step_run.id],
      preload: [attempts: ^attempts_preload_query()]
    )
  end

  defp attempts_preload_query do
    from(attempt in StepAttemptRecord,
      order_by: [asc: attempt.attempt_number, asc: attempt.inserted_at, asc: attempt.id]
    )
  end

  defp deserialize_value(value) when is_map(value), do: deserialize_map(value)
  defp deserialize_value(value) when is_list(value), do: Enum.map(value, &deserialize_value/1)
  defp deserialize_value(value), do: value

  defp deserialize_error_step(nil, step), do: step

  defp deserialize_error_step(definition, step) when is_binary(step),
    do: deserialize_step(definition, step)

  defp deserialize_error_step(_definition, step), do: step

  defp maybe_update_error_step(error, key, definition) do
    case Map.fetch(error, key) do
      {:ok, step} -> Map.put(error, key, deserialize_error_step(definition, step))
      :error -> error
    end
  end

  defp maybe_update_error_steps(error, key, definition) do
    case Map.fetch(error, key) do
      {:ok, steps} when is_list(steps) ->
        Map.put(error, key, Enum.map(steps, &deserialize_error_step(definition, &1)))

      _other ->
        error
    end
  end

  defp deserialize_key(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> key
    end
  end
end
