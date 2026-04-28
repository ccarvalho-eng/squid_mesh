defmodule SquidMesh.RunStore do
  @moduledoc false

  import Ecto.Query

  alias SquidMesh.Persistence.Run, as: RunRecord
  alias SquidMesh.Run
  alias SquidMesh.Runtime.StateMachine

  @type list_filter :: {:workflow, module()} | {:status, Run.status()} | {:limit, pos_integer()}
  @type list_filters :: [list_filter()]

  @type create_error ::
          {:invalid_input, :expected_map}
          | {:invalid_workflow, module()}
          | {:invalid_run, Ecto.Changeset.t()}

  @type get_error :: :not_found
  @type transition_attrs :: %{
          optional(:context) => map(),
          optional(:current_step) => String.t() | atom() | nil,
          optional(:last_error) => map() | nil
        }
  @type transition_error ::
          get_error() | StateMachine.transition_error() | {:invalid_run, Ecto.Changeset.t()}

  @spec create_run(module(), module(), map()) :: {:ok, Run.t()} | {:error, create_error()}
  def create_run(repo, workflow, input) when is_map(input) do
    with {:ok, definition} <- workflow_definition(workflow),
         {:ok, first_step} <- first_step(workflow, definition) do
      attrs = %{
        workflow: Atom.to_string(workflow),
        status: "pending",
        input: input,
        context: %{},
        current_step: Atom.to_string(first_step)
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
  end

  def create_run(_repo, _workflow, _input), do: {:error, {:invalid_input, :expected_map}}

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

  @spec workflow_definition(module()) :: {:ok, map()} | {:error, {:invalid_workflow, module()}}
  defp workflow_definition(workflow) do
    case Code.ensure_loaded(workflow) do
      {:module, ^workflow} ->
        if function_exported?(workflow, :workflow_definition, 0) do
          {:ok, workflow.workflow_definition()}
        else
          {:error, {:invalid_workflow, workflow}}
        end

      {:error, _reason} ->
        {:error, {:invalid_workflow, workflow}}
    end
  end

  @spec first_step(module(), map()) :: {:ok, atom()} | {:error, {:invalid_workflow, module()}}
  defp first_step(_workflow, %{steps: [%{name: step_name} | _rest]}) when is_atom(step_name),
    do: {:ok, step_name}

  defp first_step(workflow, _definition), do: {:error, {:invalid_workflow, workflow}}

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
        where(query, [run], run.workflow == ^serialize_workflow(workflow))
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
    %Run{
      id: run.id,
      workflow: deserialize_identifier(run.workflow),
      status: deserialize_status(run.status),
      input: run.input || %{},
      context: run.context || %{},
      current_step: deserialize_identifier(run.current_step),
      last_error: run.last_error,
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

  @spec deserialize_identifier(String.t() | nil) :: atom() | String.t() | nil
  defp deserialize_identifier(nil), do: nil

  defp deserialize_identifier(identifier) when is_binary(identifier) do
    try do
      String.to_existing_atom(identifier)
    rescue
      ArgumentError -> identifier
    end
  end

  @spec serialize_filters(list_filters()) :: keyword()
  defp serialize_filters(filters) do
    filters
    |> Enum.map(fn
      {:workflow, workflow} -> {:workflow, serialize_workflow(workflow)}
      {:status, status} -> {:status, serialize_status(status)}
      {:limit, limit} -> {:limit, limit}
    end)
  end

  @spec serialize_workflow(module() | String.t()) :: String.t()
  defp serialize_workflow(workflow) when is_atom(workflow), do: Atom.to_string(workflow)
  defp serialize_workflow(workflow) when is_binary(workflow), do: workflow

  @spec serialize_status(Run.status()) :: String.t()
  defp serialize_status(status) when is_atom(status), do: Atom.to_string(status)

  @spec transition_changeset_attrs(Run.status(), transition_attrs()) :: map()
  defp transition_changeset_attrs(to_status, attrs) do
    attrs
    |> Map.take([:context, :current_step, :last_error])
    |> serialize_transition_attrs()
    |> Map.put(:status, serialize_status(to_status))
  end

  defp serialize_transition_attrs(attrs) do
    Map.update(attrs, :current_step, nil, fn
      current_step when is_atom(current_step) -> Atom.to_string(current_step)
      current_step -> current_step
    end)
  end
end
