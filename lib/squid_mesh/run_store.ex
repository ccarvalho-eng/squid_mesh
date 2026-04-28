defmodule SquidMesh.RunStore do
  @moduledoc false

  alias SquidMesh.Persistence.Run, as: RunRecord
  alias SquidMesh.Run

  @type create_error ::
          {:invalid_input, :expected_map}
          | {:invalid_workflow, module()}
          | {:invalid_run, Ecto.Changeset.t()}

  @type get_error :: :not_found

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

  @spec workflow_definition(module()) :: {:ok, map()} | {:error, {:invalid_workflow, module()}}
  defp workflow_definition(workflow) do
    if function_exported?(workflow, :workflow_definition, 0) do
      {:ok, workflow.workflow_definition()}
    else
      {:error, {:invalid_workflow, workflow}}
    end
  end

  @spec first_step(module(), map()) :: {:ok, atom()} | {:error, {:invalid_workflow, module()}}
  defp first_step(_workflow, %{steps: [%{name: step_name} | _rest]}) when is_atom(step_name),
    do: {:ok, step_name}

  defp first_step(workflow, _definition), do: {:error, {:invalid_workflow, workflow}}

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
end
