defmodule SquidMesh.RunStore do
  @moduledoc """
  Durable run persistence and lifecycle operations.

  This module translates between the public `SquidMesh.Run` struct and the
  underlying persistence schema while applying workflow-level rules such as
  payload validation, trigger resolution, replay lineage, and legal run-state
  transitions.
  """

  import Ecto.Query

  alias SquidMesh.Persistence.Run, as: RunRecord
  alias SquidMesh.Observability
  alias SquidMesh.Run
  alias SquidMesh.RunStore.Persistence
  alias SquidMesh.RunStore.Serialization
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
  @type attrs_fun :: (Run.t() -> transition_attrs())
  @type progress_operation ::
          :update
          | {:transition, Run.status()}
          | {:dispatch, dispatch_fun()}
          | {:transition_or_dispatch, Run.status(), dispatch_fun()}
  @type progress_result :: Run.t() | :noop

  @doc """
  Creates a new run for a workflow using the workflow's default trigger.
  """
  @spec create_run(module(), module(), map()) :: {:ok, Run.t()} | {:error, create_error()}
  def create_run(repo, workflow, payload) when is_map(payload) do
    case create_and_dispatch_run(repo, workflow, payload, &Persistence.noop_dispatch/1) do
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
    case create_and_dispatch_run(
           repo,
           workflow,
           trigger_name,
           payload,
           &Persistence.noop_dispatch/1
         ) do
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
    case replay_and_dispatch_run(repo, run_id, &Persistence.noop_dispatch/1) do
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
      attrs = Persistence.build_run_attrs(workflow, trigger, definition, resolved_payload)
      Persistence.insert_run_with_dispatch(repo, attrs, dispatch_fun)
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
      attrs = Persistence.build_run_attrs(workflow, trigger, definition, resolved_payload)
      Persistence.insert_run_with_dispatch(repo, attrs, dispatch_fun)
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
          attrs = Persistence.replay_run_attrs(source_run, definition)
          Persistence.insert_run_with_dispatch(repo, attrs, dispatch_fun)
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
      |> Serialization.maybe_preload_history(include_history?)

    case repo.one(query) do
      %RunRecord{} = run ->
        {:ok, Serialization.to_public_run(run)}

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
      |> Enum.map(&Serialization.to_public_run/1)

    {:ok, runs}
  end

  @doc """
  Applies a validated run-state transition and persists the updated run.
  """
  @spec transition_run(module(), Ecto.UUID.t(), Run.status(), transition_attrs()) ::
          {:ok, Run.t()} | {:error, transition_error()}
  def transition_run(repo, run_id, to_status, attrs \\ %{}) when is_map(attrs) do
    repo.transaction(fn ->
      case get_run_record_for_update(repo, run_id) do
        %RunRecord{} = run ->
          from_status = Serialization.deserialize_status(run.status)

          with {:ok, _next_status} <- StateMachine.transition(from_status, to_status) do
            run
            |> RunRecord.changeset(Persistence.transition_changeset_attrs(to_status, attrs))
            |> repo.update()
            |> case do
              {:ok, updated_run} ->
                public_run = Serialization.to_public_run(updated_run)
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
           case get_run_record_for_update(repo, run_id) do
             %RunRecord{} = run ->
               from_status = Serialization.deserialize_status(run.status)

               with {:ok, _next_status} <- StateMachine.transition(from_status, to_status),
                    {:ok, updated_run} <-
                      Persistence.update_run_record(
                        repo,
                        run,
                        Persistence.transition_changeset_attrs(to_status, attrs)
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
      with {:ok, target_status} <- Persistence.cancellation_target_status(run.status) do
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
      case get_run_record_for_update(repo, run_id) do
        %RunRecord{} = run ->
          run
          |> RunRecord.changeset(
            Persistence.serialize_transition_attrs(
              Map.take(attrs, [:context, :current_step, :last_error])
            )
          )
          |> repo.update()
          |> case do
            {:ok, updated_run} -> Serialization.to_public_run(updated_run)
            {:error, changeset} -> repo.rollback({:invalid_run, changeset})
          end

        nil ->
          repo.rollback(:not_found)
      end
    end)
  end

  @doc false
  @spec update_run_with(module(), Ecto.UUID.t(), attrs_fun()) ::
          {:ok, Run.t()} | {:error, update_error()}
  def update_run_with(repo, run_id, attrs_fun) when is_function(attrs_fun, 1) do
    repo.transaction(fn ->
      case get_run_record_for_update(repo, run_id) do
        %RunRecord{} = run ->
          current_run = Serialization.to_public_run(run)
          attrs = attrs_fun.(current_run)

          run
          |> RunRecord.changeset(
            Persistence.serialize_transition_attrs(
              Map.take(attrs, [:context, :current_step, :last_error])
            )
          )
          |> repo.update()
          |> case do
            {:ok, updated_run} -> Serialization.to_public_run(updated_run)
            {:error, changeset} -> repo.rollback({:invalid_run, changeset})
          end

        nil ->
          repo.rollback(:not_found)
      end
    end)
  end

  @doc false
  @spec progress_run_with(module(), Ecto.UUID.t(), attrs_fun(), progress_operation()) ::
          {:ok, progress_result()} | {:error, update_error() | transition_error() | term()}
  def progress_run_with(repo, run_id, attrs_fun, operation)
      when is_function(attrs_fun, 1) do
    case repo.transaction(fn ->
           case get_run_record_for_update(repo, run_id) do
             %RunRecord{} = run ->
               current_run = Serialization.to_public_run(run)

               case current_run.status do
                 status when status in [:failed, :completed, :cancelled] ->
                   :noop

                 :cancelling ->
                   attrs =
                     current_run
                     |> attrs_fun.()
                     |> cancellation_progress_attrs()

                   with {:ok, _next_status} <- StateMachine.transition(:cancelling, :cancelled),
                        {:ok, updated_run} <-
                          Persistence.update_run_record(
                            repo,
                            run,
                            Persistence.transition_changeset_attrs(:cancelled, attrs)
                          ) do
                     {updated_run, :cancelling, :cancelled}
                   else
                     {:error, reason} -> repo.rollback(reason)
                   end

                 from_status ->
                   attrs = attrs_fun.(current_run)
                   execute_progress_operation(repo, run, from_status, attrs, operation)
               end

             nil ->
               repo.rollback(:not_found)
           end
         end) do
      {:ok, :noop} ->
        {:ok, :noop}

      {:ok, {run, from_status, to_status}} ->
        Observability.emit_run_transition(run, from_status, to_status)
        {:ok, run}

      {:ok, %Run{} = run} ->
        {:ok, run}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec update_and_dispatch_run(module(), Ecto.UUID.t(), transition_attrs(), dispatch_fun()) ::
          {:ok, Run.t()} | {:error, update_error() | term()}
  def update_and_dispatch_run(repo, run_id, attrs, dispatch_fun)
      when is_map(attrs) and is_function(dispatch_fun, 1) do
    case repo.transaction(fn ->
           case get_run_record_for_update(repo, run_id) do
             %RunRecord{} = run ->
               with {:ok, updated_run} <-
                      Persistence.update_run_record(
                        repo,
                        run,
                        Persistence.serialize_transition_attrs(
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

  @doc false
  @spec update_and_dispatch_run_with(module(), Ecto.UUID.t(), attrs_fun(), dispatch_fun()) ::
          {:ok, Run.t()} | {:error, update_error() | term()}
  def update_and_dispatch_run_with(repo, run_id, attrs_fun, dispatch_fun)
      when is_function(attrs_fun, 1) and is_function(dispatch_fun, 1) do
    case repo.transaction(fn ->
           case get_run_record_for_update(repo, run_id) do
             %RunRecord{} = run ->
               current_run = Serialization.to_public_run(run)
               attrs = attrs_fun.(current_run)

               with {:ok, updated_run} <-
                      Persistence.update_run_record(
                        repo,
                        run,
                        Persistence.serialize_transition_attrs(
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

  @doc false
  @spec transition_run_with(module(), Ecto.UUID.t(), Run.status(), attrs_fun()) ::
          {:ok, Run.t()} | {:error, transition_error()}
  def transition_run_with(repo, run_id, to_status, attrs_fun)
      when is_function(attrs_fun, 1) do
    repo.transaction(fn ->
      case get_run_record_for_update(repo, run_id) do
        %RunRecord{} = run ->
          from_status = Serialization.deserialize_status(run.status)
          current_run = Serialization.to_public_run(run)

          with {:ok, _next_status} <- StateMachine.transition(from_status, to_status) do
            attrs = attrs_fun.(current_run)

            run
            |> RunRecord.changeset(Persistence.transition_changeset_attrs(to_status, attrs))
            |> repo.update()
            |> case do
              {:ok, updated_run} ->
                public_run = Serialization.to_public_run(updated_run)
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
      repo.list_runs(Serialization.serialize_filters(filters))
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
        where(query, [run], run.status == ^Serialization.serialize_status(status))
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

  @spec execute_progress_operation(
          module(),
          RunRecord.t(),
          Run.status(),
          transition_attrs(),
          progress_operation()
        ) :: Run.t() | {Run.t(), Run.status(), Run.status()} | no_return()
  defp execute_progress_operation(repo, run, _from_status, attrs, :update) do
    case Persistence.update_run_record(
           repo,
           run,
           Persistence.serialize_transition_attrs(
             Map.take(attrs, [:context, :current_step, :last_error])
           )
         ) do
      {:ok, updated_run} ->
        updated_run

      {:error, reason} ->
        repo.rollback(reason)
    end
  end

  defp execute_progress_operation(repo, run, from_status, attrs, {:transition, to_status}) do
    with {:ok, _next_status} <- StateMachine.transition(from_status, to_status),
         {:ok, updated_run} <-
           Persistence.update_run_record(
             repo,
             run,
             Persistence.transition_changeset_attrs(to_status, attrs)
           ) do
      {updated_run, from_status, to_status}
    else
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp execute_progress_operation(repo, run, _from_status, attrs, {:dispatch, dispatch_fun}) do
    with {:ok, updated_run} <-
           Persistence.update_run_record(
             repo,
             run,
             Persistence.serialize_transition_attrs(
               Map.take(attrs, [:context, :current_step, :last_error])
             )
           ),
         {:ok, _result} <- dispatch_fun.(updated_run) do
      updated_run
    else
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp execute_progress_operation(
         repo,
         run,
         from_status,
         attrs,
         {:transition_or_dispatch, to_status, dispatch_fun}
       ) do
    if from_status == to_status do
      with {:ok, updated_run} <-
             Persistence.update_run_record(
               repo,
               run,
               Persistence.serialize_transition_attrs(
                 Map.take(attrs, [:context, :current_step, :last_error])
               )
             ),
           {:ok, _result} <- dispatch_fun.(updated_run) do
        updated_run
      else
        {:error, reason} -> repo.rollback(reason)
      end
    else
      with {:ok, _next_status} <- StateMachine.transition(from_status, to_status),
           {:ok, updated_run} <-
             Persistence.update_run_record(
               repo,
               run,
               Persistence.transition_changeset_attrs(to_status, attrs)
             ),
           {:ok, _result} <- dispatch_fun.(updated_run) do
        {updated_run, from_status, to_status}
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end
  end

  @spec cancellation_progress_attrs(transition_attrs()) :: transition_attrs()
  defp cancellation_progress_attrs(attrs) do
    attrs
    |> Map.take([:context])
    |> Map.put(:current_step, nil)
    |> Map.put(:last_error, nil)
  end

  @spec get_run_record_for_update(module(), Ecto.UUID.t()) :: RunRecord.t() | nil
  defp get_run_record_for_update(repo, run_id) do
    RunRecord
    |> where([run], run.id == ^run_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end
end
