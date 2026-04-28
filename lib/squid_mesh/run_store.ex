defmodule SquidMesh.RunStore do
  @moduledoc """
  Durable run persistence and lifecycle operations.

  This module translates between the public `SquidMesh.Run` struct and the
  underlying persistence schema while applying workflow-level rules such as
  payload validation, trigger resolution, replay lineage, and legal run-state
  transitions.
  """

  import Ecto.Query

  alias SquidMesh.Persistence.StepAttempt, as: StepAttemptRecord
  alias SquidMesh.Persistence.Run, as: RunRecord
  alias SquidMesh.Persistence.StepRun, as: StepRunRecord
  alias SquidMesh.Observability
  alias SquidMesh.Run
  alias SquidMesh.StepAttempt
  alias SquidMesh.StepRun
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
  @type get_option :: {:include_history, boolean()}
  @type dispatch_fun :: (Run.t() -> {:ok, term()} | {:error, term()})

  @doc """
  Creates a new run for a workflow using the workflow's default trigger.
  """
  @spec create_run(module(), module(), map()) :: {:ok, Run.t()} | {:error, create_error()}
  def create_run(repo, workflow, payload) when is_map(payload) do
    case create_and_dispatch_run(repo, workflow, payload, &noop_dispatch/1) do
      {:ok, run} ->
        Observability.emit_run_created(run)
        {:ok, run}

      {:error, _reason} = error ->
        error
    end
  end

  def create_run(_repo, _workflow, _payload), do: {:error, {:invalid_payload, :expected_map}}

  @doc """
  Creates a new run for a workflow through an explicit trigger.
  """
  @spec create_run(module(), module(), atom(), map()) :: {:ok, Run.t()} | {:error, create_error()}
  def create_run(repo, workflow, trigger_name, payload)
      when is_atom(trigger_name) and is_map(payload) do
    case create_and_dispatch_run(repo, workflow, trigger_name, payload, &noop_dispatch/1) do
      {:ok, run} ->
        Observability.emit_run_created(run)
        {:ok, run}

      {:error, _reason} = error ->
        error
    end
  end

  def create_run(_repo, _workflow, _trigger_name, _payload),
    do: {:error, {:invalid_payload, :expected_map}}

  @doc """
  Creates a new pending run from a prior run while preserving replay lineage.
  """
  @spec replay_run(module(), Ecto.UUID.t()) :: {:ok, Run.t()} | {:error, replay_error()}
  def replay_run(repo, run_id) do
    case replay_and_dispatch_run(repo, run_id, &noop_dispatch/1) do
      {:ok, replay_run} ->
        Observability.emit_run_replayed(replay_run)
        {:ok, replay_run}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec create_and_dispatch_run(module(), module(), map(), dispatch_fun()) ::
          {:ok, Run.t()} | {:error, create_error() | term()}
  def create_and_dispatch_run(repo, workflow, payload, dispatch_fun)
      when is_map(payload) and is_function(dispatch_fun, 1) do
    with {:ok, definition} <- WorkflowDefinition.load(workflow),
         {:ok, trigger} <-
           WorkflowDefinition.resolve_trigger(
             definition,
             WorkflowDefinition.default_trigger(definition)
           ),
         {:ok, resolved_payload} <- WorkflowDefinition.resolve_payload(definition, payload) do
      attrs = build_run_attrs(workflow, trigger, definition, resolved_payload)
      insert_run_with_dispatch(repo, attrs, dispatch_fun)
    end
  end

  @doc false
  @spec create_and_dispatch_run(module(), module(), atom(), map(), dispatch_fun()) ::
          {:ok, Run.t()} | {:error, create_error() | term()}
  def create_and_dispatch_run(repo, workflow, trigger_name, payload, dispatch_fun)
      when is_atom(trigger_name) and is_map(payload) and is_function(dispatch_fun, 1) do
    with {:ok, definition} <- WorkflowDefinition.load(workflow),
         {:ok, trigger} <- WorkflowDefinition.resolve_trigger(definition, trigger_name),
         {:ok, resolved_payload} <- WorkflowDefinition.resolve_payload(definition, payload) do
      attrs = build_run_attrs(workflow, trigger, definition, resolved_payload)
      insert_run_with_dispatch(repo, attrs, dispatch_fun)
    end
  end

  @doc false
  @spec replay_and_dispatch_run(module(), Ecto.UUID.t(), dispatch_fun()) ::
          {:ok, Run.t()} | {:error, replay_error() | term()}
  def replay_and_dispatch_run(repo, run_id, dispatch_fun) when is_function(dispatch_fun, 1) do
    case repo.get(RunRecord, run_id) do
      %RunRecord{} = source_run ->
        with {:ok, _workflow, definition} <-
               WorkflowDefinition.load_serialized(source_run.workflow) do
          attrs = replay_run_attrs(source_run, definition)
          insert_run_with_dispatch(repo, attrs, dispatch_fun)
        end

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Fetches one persisted run and returns the public run representation.
  """
  @spec get_run(module(), Ecto.UUID.t(), [get_option()]) :: {:ok, Run.t()} | {:error, get_error()}
  def get_run(repo, run_id, opts \\ []) do
    include_history? = Keyword.get(opts, :include_history, false)

    query =
      RunRecord
      |> where([run], run.id == ^run_id)
      |> maybe_preload_history(include_history?)

    case repo.one(query) do
      %RunRecord{} = run ->
        {:ok, to_public_run(run)}

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Lists runs using the supported filter set.
  """
  @spec list_runs(module(), list_filters()) :: {:ok, [Run.t()]}
  def list_runs(repo, filters \\ []) do
    runs =
      repo
      |> query_runs(filters)
      |> Enum.map(&to_public_run/1)

    {:ok, runs}
  end

  @doc """
  Applies a validated run-state transition and persists the updated run.
  """
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
              {:ok, updated_run} ->
                public_run = to_public_run(updated_run)
                Observability.emit_run_transition(public_run, from_status, to_status)
                public_run

              {:error, changeset} ->
                repo.rollback({:invalid_run, changeset})
            end
          else
            {:error, reason} -> repo.rollback(reason)
          end

        nil ->
          repo.rollback(:not_found)
      end
    end)
  end

  @doc false
  @spec transition_and_dispatch_run(
          module(),
          Ecto.UUID.t(),
          Run.status(),
          transition_attrs(),
          dispatch_fun()
        ) :: {:ok, Run.t()} | {:error, transition_error() | term()}
  def transition_and_dispatch_run(repo, run_id, to_status, attrs, dispatch_fun)
      when is_map(attrs) and is_function(dispatch_fun, 1) do
    case repo.transaction(fn ->
           case repo.get(RunRecord, run_id) do
             %RunRecord{} = run ->
               from_status = deserialize_status(run.status)

               with {:ok, _next_status} <- StateMachine.transition(from_status, to_status),
                    {:ok, updated_run} <-
                      update_run_record(
                        repo,
                        run,
                        transition_changeset_attrs(to_status, attrs)
                      ),
                    {:ok, _result} <- dispatch_fun.(updated_run) do
                 {updated_run, from_status}
               else
                 {:error, reason} -> repo.rollback(reason)
               end

             nil ->
               repo.rollback(:not_found)
           end
         end) do
      {:ok, {run, from_status}} ->
        Observability.emit_run_transition(run, from_status, to_status)
        {:ok, run}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Requests cancellation for a run if its current status allows it.
  """
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

  @doc """
  Updates durable run fields without changing the run state machine directly.
  """
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

  @doc false
  @spec update_and_dispatch_run(module(), Ecto.UUID.t(), transition_attrs(), dispatch_fun()) ::
          {:ok, Run.t()} | {:error, update_error() | term()}
  def update_and_dispatch_run(repo, run_id, attrs, dispatch_fun)
      when is_map(attrs) and is_function(dispatch_fun, 1) do
    case repo.transaction(fn ->
           case repo.get(RunRecord, run_id) do
             %RunRecord{} = run ->
               with {:ok, updated_run} <-
                      update_run_record(
                        repo,
                        run,
                        serialize_transition_attrs(
                          Map.take(attrs, [:context, :current_step, :last_error])
                        )
                      ),
                    {:ok, _result} <- dispatch_fun.(updated_run) do
                 updated_run
               else
                 {:error, reason} -> repo.rollback(reason)
               end

             nil ->
               repo.rollback(:not_found)
           end
         end) do
      {:ok, run} -> {:ok, run}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns whether a run in the given state should schedule additional step work.
  """
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
      last_error: deserialize_run_error(definition, run.last_error),
      step_runs: to_public_step_runs(run, definition),
      replayed_from_run_id: run.replayed_from_run_id,
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end

  @spec to_public_step_runs(RunRecord.t(), WorkflowDefinition.t() | nil) :: [StepRun.t()] | nil
  defp to_public_step_runs(%RunRecord{step_runs: %Ecto.Association.NotLoaded{}}, _definition),
    do: nil

  defp to_public_step_runs(%RunRecord{step_runs: step_runs}, definition)
       when is_list(step_runs) do
    Enum.map(step_runs, &to_public_step_run(&1, definition))
  end

  @spec to_public_step_run(StepRunRecord.t(), WorkflowDefinition.t() | nil) :: StepRun.t()
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

  @spec to_public_attempts(StepRunRecord.t()) :: [StepAttempt.t()]
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

  @spec deserialize_status(String.t()) :: Run.status()
  defp deserialize_status("pending"), do: :pending
  defp deserialize_status("running"), do: :running
  defp deserialize_status("retrying"), do: :retrying
  defp deserialize_status("failed"), do: :failed
  defp deserialize_status("completed"), do: :completed
  defp deserialize_status("cancelling"), do: :cancelling
  defp deserialize_status("cancelled"), do: :cancelled

  @spec deserialize_step_status(String.t()) :: StepRun.status()
  defp deserialize_step_status("running"), do: :running
  defp deserialize_step_status("completed"), do: :completed
  defp deserialize_step_status("failed"), do: :failed

  @spec deserialize_attempt_status(String.t()) :: StepAttempt.status()
  defp deserialize_attempt_status("completed"), do: :completed
  defp deserialize_attempt_status("failed"), do: :failed

  @spec deserialize_workflow(String.t()) :: {module() | String.t(), WorkflowDefinition.t() | nil}
  defp deserialize_workflow(workflow_name) do
    case WorkflowDefinition.load_serialized(workflow_name) do
      {:ok, workflow, definition} -> {workflow, definition}
      {:error, _reason} -> {workflow_name, nil}
    end
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

  @spec maybe_preload_history(Ecto.Queryable.t(), boolean()) :: Ecto.Query.t()
  defp maybe_preload_history(query, true) do
    preload(query, [run], step_runs: ^step_runs_preload_query())
  end

  defp maybe_preload_history(query, false), do: query

  @spec build_run_attrs(module(), atom(), WorkflowDefinition.t(), map()) :: map()
  defp build_run_attrs(workflow, trigger, definition, resolved_payload) do
    %{
      workflow: WorkflowDefinition.serialize_workflow(workflow),
      trigger: WorkflowDefinition.serialize_trigger(trigger),
      status: "pending",
      input: resolved_payload,
      context: %{},
      current_step: WorkflowDefinition.serialize_step(WorkflowDefinition.entry_step(definition))
    }
  end

  @spec replay_run_attrs(RunRecord.t(), WorkflowDefinition.t()) :: map()
  defp replay_run_attrs(source_run, definition) do
    %{
      workflow: source_run.workflow,
      trigger: source_run.trigger,
      status: "pending",
      input: source_run.input || %{},
      context: %{},
      current_step: WorkflowDefinition.serialize_step(WorkflowDefinition.entry_step(definition)),
      replayed_from_run_id: source_run.id
    }
  end

  @spec insert_run_with_dispatch(module(), map(), dispatch_fun()) ::
          {:ok, Run.t()} | {:error, {:invalid_run, Ecto.Changeset.t()} | term()}
  defp insert_run_with_dispatch(repo, attrs, dispatch_fun) do
    case repo.transaction(fn ->
           with {:ok, run} <- insert_run_record(repo, attrs),
                {:ok, _result} <- dispatch_fun.(run) do
             run
           else
             {:error, reason} -> repo.rollback(reason)
           end
         end) do
      {:ok, run} -> {:ok, run}
      {:error, _reason} = error -> error
    end
  end

  @spec insert_run_record(module(), map()) ::
          {:ok, Run.t()} | {:error, {:invalid_run, Ecto.Changeset.t()}}
  defp insert_run_record(repo, attrs) do
    %RunRecord{}
    |> RunRecord.changeset(attrs)
    |> repo.insert()
    |> case do
      {:ok, run} -> {:ok, to_public_run(run)}
      {:error, changeset} -> {:error, {:invalid_run, changeset}}
    end
  end

  @spec update_run_record(module(), RunRecord.t(), map()) ::
          {:ok, Run.t()} | {:error, {:invalid_run, Ecto.Changeset.t()}}
  defp update_run_record(repo, run, attrs) do
    run
    |> RunRecord.changeset(attrs)
    |> repo.update()
    |> case do
      {:ok, updated_run} -> {:ok, to_public_run(updated_run)}
      {:error, changeset} -> {:error, {:invalid_run, changeset}}
    end
  end

  @spec noop_dispatch(Run.t()) :: {:ok, :noop}
  defp noop_dispatch(_run), do: {:ok, :noop}

  @spec step_runs_preload_query() :: Ecto.Query.t()
  defp step_runs_preload_query do
    from(step_run in StepRunRecord,
      order_by: [asc: step_run.inserted_at, asc: step_run.id],
      preload: [attempts: ^attempts_preload_query()]
    )
  end

  @spec attempts_preload_query() :: Ecto.Query.t()
  defp attempts_preload_query do
    from(attempt in StepAttemptRecord,
      order_by: [asc: attempt.attempt_number, asc: attempt.inserted_at, asc: attempt.id]
    )
  end

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

  @spec deserialize_run_error(WorkflowDefinition.t() | nil, map() | nil) :: map() | nil
  defp deserialize_run_error(_definition, nil), do: nil

  defp deserialize_run_error(definition, error) when is_map(error) do
    error
    |> deserialize_map()
    |> maybe_update_error_step(:next_step, definition)
    |> maybe_update_error_step(:failed_step, definition)
  end

  @spec deserialize_error_step(WorkflowDefinition.t() | nil, atom() | String.t() | nil) ::
          atom() | String.t() | nil
  defp deserialize_error_step(nil, step), do: step

  defp deserialize_error_step(definition, step) when is_binary(step),
    do: deserialize_step(definition, step)

  defp deserialize_error_step(_definition, step), do: step

  @spec maybe_update_error_step(map(), atom(), WorkflowDefinition.t() | nil) :: map()
  defp maybe_update_error_step(error, key, definition) do
    case Map.fetch(error, key) do
      {:ok, step} -> Map.put(error, key, deserialize_error_step(definition, step))
      :error -> error
    end
  end

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
