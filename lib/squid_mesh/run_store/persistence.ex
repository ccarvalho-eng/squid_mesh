defmodule SquidMesh.RunStore.Persistence do
  @moduledoc """
  Write-side persistence helpers for workflow runs.

  These helpers keep record construction and serialization close to the
  database-facing code while `SquidMesh.RunStore` continues to expose the
  public lifecycle API.
  """

  alias SquidMesh.Persistence.Run, as: RunRecord
  alias SquidMesh.Run
  alias SquidMesh.RunStore.Serialization
  alias SquidMesh.Workflow.Definition, as: WorkflowDefinition

  @type transition_attrs :: %{
          optional(:context) => map(),
          optional(:current_step) => String.t() | atom() | nil,
          optional(:last_error) => map() | nil
        }

  @spec build_run_attrs(module(), atom(), WorkflowDefinition.t(), map()) :: map()
  def build_run_attrs(workflow, trigger, definition, resolved_payload) do
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
  def replay_run_attrs(source_run, definition) do
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

  @spec transition_changeset_attrs(Run.status(), transition_attrs()) :: map()
  def transition_changeset_attrs(to_status, attrs) do
    attrs
    |> Map.take([:context, :current_step, :last_error])
    |> serialize_transition_attrs()
    |> Map.put(:status, Serialization.serialize_status(to_status))
  end

  @spec serialize_transition_attrs(map()) :: map()
  def serialize_transition_attrs(attrs) do
    Map.update(attrs, :current_step, nil, fn
      nil -> nil
      current_step when is_atom(current_step) -> Atom.to_string(current_step)
      current_step -> current_step
    end)
  end

  @spec insert_run_record(module(), map()) ::
          {:ok, Run.t()} | {:error, {:invalid_run, Ecto.Changeset.t()}}
  def insert_run_record(repo, attrs) do
    %RunRecord{}
    |> RunRecord.changeset(attrs)
    |> repo.insert()
    |> case do
      {:ok, run} -> {:ok, Serialization.to_public_run(run)}
      {:error, changeset} -> {:error, {:invalid_run, changeset}}
    end
  end

  @spec update_run_record(module(), RunRecord.t(), map()) ::
          {:ok, Run.t()} | {:error, {:invalid_run, Ecto.Changeset.t()}}
  def update_run_record(repo, run, attrs) do
    run
    |> RunRecord.changeset(attrs)
    |> repo.update()
    |> case do
      {:ok, updated_run} -> {:ok, Serialization.to_public_run(updated_run)}
      {:error, changeset} -> {:error, {:invalid_run, changeset}}
    end
  end

  @spec insert_run_with_dispatch(module(), map(), (Run.t() -> {:ok, term()} | {:error, term()})) ::
          {:ok, Run.t()} | {:error, {:invalid_run, Ecto.Changeset.t()} | term()}
  def insert_run_with_dispatch(repo, attrs, dispatch_fun) do
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

  @spec noop_dispatch(Run.t()) :: {:ok, :noop}
  def noop_dispatch(_run), do: {:ok, :noop}

  @spec cancellation_target_status(Run.status()) ::
          {:ok, Run.status()} | {:error, {:invalid_transition, Run.status(), Run.status()}}
  def cancellation_target_status(:pending), do: {:ok, :cancelled}
  def cancellation_target_status(:running), do: {:ok, :cancelling}
  def cancellation_target_status(:retrying), do: {:ok, :cancelling}
  def cancellation_target_status(state), do: {:error, {:invalid_transition, state, :cancelling}}
end
