defmodule SquidMesh.RunStore do
  @moduledoc false

  import Ecto.Query

  alias SquidMesh.Persistence.Run, as: RunRecord
  alias SquidMesh.Run
  alias SquidMesh.Runtime.StateMachine
  alias SquidMesh.Workflow.Definition, as: WorkflowDefinition

  @type list_filter :: {:workflow, module()} | {:status, Run.status()} | {:limit, pos_integer()}
  @type list_filters :: [list_filter()]

  @type create_error ::
          {:invalid_payload, :expected_map}
          | {:invalid_payload, WorkflowDefinition.payload_error_details()}
          | {:invalid_trigger, atom() | String.t()}
          | {:invalid_workflow, module() | String.t()}
          | {:invalid_run, Ecto.Changeset.t()}

  @type get_error :: :not_found
  @type transition_attrs :: %{
          optional(:context) => map(),
          optional(:current_step) => String.t() | atom() | nil,
          optional(:last_error) => map() | nil
        }
  @type transition_error ::
          get_error() | StateMachine.transition_error() | {:invalid_run, Ecto.Changeset.t()}
  @type replay_error :: get_error() | create_error()
  @type update_error :: get_error() | {:invalid_run, Ecto.Changeset.t()}

  @spec create_run(module(), module(), map()) :: {:ok, Run.t()} | {:error, create_error()}
  def create_run(repo, workflow, payload) when is_map(payload) do
    with {:ok, definition} <- WorkflowDefinition.load(workflow),
         {:ok, trigger} <-
           WorkflowDefinition.resolve_trigger(
             definition,
             WorkflowDefinition.default_trigger(definition)
           ),
         {:ok, resolved_payload} <- WorkflowDefinition.resolve_payload(definition, payload) do
      persist_run(repo, workflow, trigger, definition, resolved_payload)
    end
  end

  def create_run(_repo, _workflow, _payload), do: {:error, {:invalid_payload, :expected_map}}

  @spec create_run(module(), module(), atom(), map()) :: {:ok, Run.t()} | {:error, create_error()}
  def create_run(repo, workflow, trigger_name, payload)
      when is_atom(trigger_name) and is_map(payload) do
    with {:ok, definition} <- WorkflowDefinition.load(workflow),
         {:ok, trigger} <- WorkflowDefinition.resolve_trigger(definition, trigger_name),
         {:ok, resolved_payload} <- WorkflowDefinition.resolve_payload(definition, payload) do
      persist_run(repo, workflow, trigger, definition, resolved_payload)
    end
  end

  def create_run(_repo, _workflow, _trigger_name, _payload),
    do: {:error, {:invalid_payload, :expected_map}}

  @doc """
  Creates a new pending run from a prior run while preserving replay lineage.
  """
  @spec replay_run(module(), Ecto.UUID.t()) :: {:ok, Run.t()} | {:error, replay_error()}
  def replay_run(repo, run_id) do
    case repo.get(RunRecord, run_id) do
      %RunRecord{} = source_run ->
        with {:ok, _workflow, definition} <-
               WorkflowDefinition.load_serialized(source_run.workflow) do
          attrs = %{
            workflow: source_run.workflow,
            trigger: source_run.trigger,
            status: "pending",
            input: source_run.input || %{},
            context: %{},
            current_step:
              WorkflowDefinition.serialize_step(WorkflowDefinition.entry_step(definition)),
            replayed_from_run_id: source_run.id
          }

          repo.transaction(fn ->
            %RunRecord{}
            |> RunRecord.changeset(attrs)
            |> repo.insert()
            |> case do
              {:ok, replay_run} -> to_public_run(replay_run)
              {:error, changeset} -> repo.rollback({:invalid_run, changeset})
            end
          end)
        end

      nil ->
        {:error, :not_found}
    end
  end

  @spec get_run(module(), Ecto.UUID.t()) :: {:ok, Run.t()} | {:error, get_error()}
  def get_run(repo, run_id) do
    case repo.get(RunRecord, run_id) do
      %RunRecord{} = run ->
        {:ok, to_public_run(run)}

      nil ->
        {:error, :not_found}
    end
  end

  @spec list_runs(module(), list_filters()) :: {:ok, [Run.t()]}
  def list_runs(repo, filters \\ []) do
    runs =
      repo
      |> query_runs(filters)
      |> Enum.map(&to_public_run/1)

    {:ok, runs}
  end

  @spec transition_run(module(), Ecto.UUID.t(), Run.status(), transition_attrs()) ::
          {:ok, Run.t()} | {:error, transition_error()}
  def transition_run(repo, run_id, to_status, attrs \\ %{}) when is_map(attrs) do
    repo.transaction(fn ->
      case repo.get(RunRecord, run_id) do
        %RunRecord{} = run ->
          from_status = deserialize_status(run.status)

          with {:ok, _next_status} <- StateMachine.transition(from_status, to_status) do
            run
            |> RunRecord.changeset(transition_changeset_attrs(to_status, attrs))
            |> repo.update()
            |> case do
              {:ok, updated_run} -> to_public_run(updated_run)
              {:error, changeset} -> repo.rollback({:invalid_run, changeset})
            end
          else
            {:error, reason} -> repo.rollback(reason)
          end

        nil ->
          repo.rollback(:not_found)
      end
    end)
  end

  @spec cancel_run(module(), Ecto.UUID.t()) :: {:ok, Run.t()} | {:error, transition_error()}
  def cancel_run(repo, run_id) do
    with {:ok, run} <- get_run(repo, run_id) do
      with {:ok, target_status} <- cancellation_target_status(run.status) do
        transition_run(repo, run_id, target_status)
      end
    else
      {:error, _reason} = error ->
        error
    end
  end

  @spec update_run(module(), Ecto.UUID.t(), transition_attrs()) ::
          {:ok, Run.t()} | {:error, update_error()}
  def update_run(repo, run_id, attrs) when is_map(attrs) do
    repo.transaction(fn ->
      case repo.get(RunRecord, run_id) do
        %RunRecord{} = run ->
          run
          |> RunRecord.changeset(
            serialize_transition_attrs(Map.take(attrs, [:context, :current_step, :last_error]))
          )
          |> repo.update()
          |> case do
            {:ok, updated_run} -> to_public_run(updated_run)
            {:error, changeset} -> repo.rollback({:invalid_run, changeset})
          end

        nil ->
          repo.rollback(:not_found)
      end
    end)
  end

  @spec schedule_next_step?(Run.t() | Run.status()) :: boolean()
  def schedule_next_step?(%Run{status: status}), do: StateMachine.schedule_next_step?(status)

  def schedule_next_step?(status) when is_atom(status),
    do: StateMachine.schedule_next_step?(status)

  @spec query_runs(module(), list_filters()) :: [RunRecord.t()]
  defp query_runs(repo, filters) do
    if function_exported?(repo, :list_runs, 1) do
      repo.list_runs(serialize_filters(filters))
    else
      RunRecord
      |> maybe_filter_workflow(filters)
      |> maybe_filter_status(filters)
      |> order_by([run], desc: run.inserted_at, desc: run.id)
      |> maybe_limit(filters)
      |> repo.all()
    end
  end

  @spec maybe_filter_workflow(Ecto.Queryable.t(), list_filters()) :: Ecto.Query.t()
  defp maybe_filter_workflow(query, filters) do
    case Keyword.get(filters, :workflow) do
      nil ->
        query

      workflow ->
        where(query, [run], run.workflow == ^WorkflowDefinition.serialize_workflow(workflow))
    end
  end

  @spec maybe_filter_status(Ecto.Queryable.t(), list_filters()) :: Ecto.Query.t()
  defp maybe_filter_status(query, filters) do
    case Keyword.get(filters, :status) do
      nil ->
        query

      status ->
        where(query, [run], run.status == ^serialize_status(status))
    end
  end

  @spec maybe_limit(Ecto.Queryable.t(), list_filters()) :: Ecto.Query.t()
  defp maybe_limit(query, filters) do
    case Keyword.get(filters, :limit) do
      limit when is_integer(limit) and limit > 0 ->
        limit(query, ^limit)

      _ ->
        query
    end
  end

  @spec to_public_run(RunRecord.t()) :: Run.t()
  defp to_public_run(run) do
    {workflow, definition} = deserialize_workflow(run.workflow)

    %Run{
      id: run.id,
      workflow: workflow,
      trigger: WorkflowDefinition.deserialize_trigger(definition, run.trigger),
      status: deserialize_status(run.status),
      payload: WorkflowDefinition.deserialize_payload(definition, run.input || %{}),
      context: deserialize_map(run.context || %{}),
      current_step: deserialize_step(definition, run.current_step),
      last_error: deserialize_map(run.last_error),
      replayed_from_run_id: run.replayed_from_run_id,
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end

  @spec deserialize_status(String.t()) :: Run.status()
  defp deserialize_status("pending"), do: :pending
  defp deserialize_status("running"), do: :running
  defp deserialize_status("retrying"), do: :retrying
  defp deserialize_status("failed"), do: :failed
  defp deserialize_status("completed"), do: :completed
  defp deserialize_status("cancelling"), do: :cancelling
  defp deserialize_status("cancelled"), do: :cancelled

  @spec deserialize_workflow(String.t()) :: {module() | String.t(), WorkflowDefinition.t() | nil}
  defp deserialize_workflow(workflow_name) do
    case WorkflowDefinition.load_serialized(workflow_name) do
      {:ok, workflow, definition} -> {workflow, definition}
      {:error, _reason} -> {workflow_name, nil}
    end
  end

  defp persist_run(repo, workflow, trigger, definition, resolved_payload) do
    attrs = %{
      workflow: WorkflowDefinition.serialize_workflow(workflow),
      trigger: WorkflowDefinition.serialize_trigger(trigger),
      status: "pending",
      input: resolved_payload,
      context: %{},
      current_step: WorkflowDefinition.serialize_step(WorkflowDefinition.entry_step(definition))
    }

    repo.transaction(fn ->
      %RunRecord{}
      |> RunRecord.changeset(attrs)
      |> repo.insert()
      |> case do
        {:ok, run} -> to_public_run(run)
        {:error, changeset} -> repo.rollback({:invalid_run, changeset})
      end
    end)
  end

  @spec deserialize_step(WorkflowDefinition.t() | nil, String.t() | nil) ::
          atom() | String.t() | nil
  defp deserialize_step(nil, step_name), do: step_name

  defp deserialize_step(definition, step_name) do
    WorkflowDefinition.deserialize_step(definition, step_name)
  end

  @spec serialize_filters(list_filters()) :: keyword()
  defp serialize_filters(filters) do
    filters
    |> Enum.map(fn
      {:workflow, workflow} -> {:workflow, WorkflowDefinition.serialize_workflow(workflow)}
      {:status, status} -> {:status, serialize_status(status)}
      {:limit, limit} -> {:limit, limit}
    end)
  end

  @spec serialize_status(Run.status()) :: String.t()
  defp serialize_status(status) when is_atom(status), do: Atom.to_string(status)

  @spec deserialize_map(map() | nil) :: map() | nil
  defp deserialize_map(nil), do: nil

  defp deserialize_map(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        {deserialize_key(key), deserialize_value(value)}

      {key, value} ->
        {key, deserialize_value(value)}
    end)
  end

  @spec deserialize_value(term()) :: term()
  defp deserialize_value(value) when is_map(value), do: deserialize_map(value)
  defp deserialize_value(value) when is_list(value), do: Enum.map(value, &deserialize_value/1)
  defp deserialize_value(value), do: value

  @spec deserialize_key(String.t()) :: atom() | String.t()
  defp deserialize_key(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> key
    end
  end

  @spec cancellation_target_status(Run.status()) ::
          {:ok, Run.status()} | {:error, {:invalid_transition, Run.status(), Run.status()}}
  defp cancellation_target_status(:pending), do: {:ok, :cancelled}
  defp cancellation_target_status(:running), do: {:ok, :cancelling}
  defp cancellation_target_status(:retrying), do: {:ok, :cancelling}
  defp cancellation_target_status(state), do: {:error, {:invalid_transition, state, :cancelling}}

  @spec transition_changeset_attrs(Run.status(), transition_attrs()) :: map()
  defp transition_changeset_attrs(to_status, attrs) do
    attrs
    |> Map.take([:context, :current_step, :last_error])
    |> serialize_transition_attrs()
    |> Map.put(:status, serialize_status(to_status))
  end

  defp serialize_transition_attrs(attrs) do
    Map.update(attrs, :current_step, nil, fn
      nil -> nil
      current_step when is_atom(current_step) -> Atom.to_string(current_step)
      current_step -> current_step
    end)
  end
end
