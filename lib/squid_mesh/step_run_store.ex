defmodule SquidMesh.StepRunStore do
  @moduledoc """
  Durable store for per-step workflow execution state.

  Step runs are used to detect stale or duplicate deliveries and to persist
  step input, output, and failure details separately from the parent run.
  """

  import Ecto.Query

  alias SquidMesh.Persistence.StepRun

  @type step_identifier :: atom() | String.t()
  @type step_input :: map()
  @type step_output :: map()
  @type step_error :: map()
  @type begin_result :: {:ok, StepRun.t(), :execute | :skip} | {:error, Ecto.Changeset.t()}

  @doc """
  Marks a step as ready for execution if it has not already completed or been
  claimed by another delivery of the same workflow step.
  """
  @spec begin_step(module(), Ecto.UUID.t(), step_identifier(), step_input()) :: begin_result()
  def begin_step(repo, run_id, step, input) when is_map(input) do
    serialized_step = serialize_step(step)

    attrs = %{
      run_id: run_id,
      step: serialized_step,
      status: "running",
      input: input,
      output: nil,
      last_error: nil
    }

    case insert_step_run(repo, attrs) do
      {:ok, step_run} ->
        {:ok, step_run, :execute}

      {:error, %Ecto.Changeset{} = changeset} ->
        if duplicate_step_claim?(changeset) do
          claim_existing_step(repo, run_id, serialized_step, attrs)
        else
          {:error, changeset}
        end
    end
  end

  @doc """
  Marks a step run as completed and persists its output.
  """
  @spec complete_step(module(), Ecto.UUID.t(), step_output()) ::
          {:ok, StepRun.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def complete_step(repo, step_run_id, output) when is_map(output) do
    update_step(repo, step_run_id, %{status: "completed", output: output, last_error: nil})
  end

  @doc """
  Marks a step run as failed and persists the last error.
  """
  @spec fail_step(module(), Ecto.UUID.t(), step_error()) ::
          {:ok, StepRun.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def fail_step(repo, step_run_id, error) when is_map(error) do
    update_step(repo, step_run_id, %{status: "failed", last_error: error})
  end

  @doc """
  Fetches the persisted step run for one workflow run and step identifier.
  """
  @spec get_step_run(module(), Ecto.UUID.t(), step_identifier()) :: StepRun.t() | nil
  def get_step_run(repo, run_id, step) do
    serialized_step = serialize_step(step)

    StepRun
    |> where([step_run], step_run.run_id == ^run_id and step_run.step == ^serialized_step)
    |> repo.one()
  end

  @doc """
  Lists the completed step identifiers for one workflow run.
  """
  @spec completed_steps(module(), Ecto.UUID.t()) :: [String.t()]
  def completed_steps(repo, run_id) do
    StepRun
    |> where([step_run], step_run.run_id == ^run_id and step_run.status == "completed")
    |> order_by([step_run], asc: step_run.inserted_at)
    |> select([step_run], step_run.step)
    |> repo.all()
  end

  @spec insert_step_run(module(), map()) :: {:ok, StepRun.t()} | {:error, Ecto.Changeset.t()}
  defp insert_step_run(repo, attrs) do
    %StepRun{}
    |> StepRun.changeset(attrs)
    |> repo.insert()
  end

  @spec claim_existing_step(module(), Ecto.UUID.t(), String.t(), map()) :: begin_result()
  defp claim_existing_step(repo, run_id, step, attrs) do
    case transition_failed_step_to_running(repo, run_id, step, attrs) do
      {:ok, %StepRun{} = step_run} ->
        {:ok, step_run, :execute}

      :not_updated ->
        case get_step_run(repo, run_id, step) do
          %StepRun{status: status} = step_run when status in ["running", "completed"] ->
            {:ok, step_run, :skip}

          %StepRun{} = step_run ->
            {:ok, step_run, :skip}

          nil ->
            insert_step_run(repo, attrs)
            |> case do
              {:ok, step_run} -> {:ok, step_run, :execute}
              {:error, changeset} -> {:error, changeset}
            end
        end
    end
  end

  @spec transition_failed_step_to_running(module(), Ecto.UUID.t(), String.t(), map()) ::
          {:ok, StepRun.t()} | :not_updated
  defp transition_failed_step_to_running(repo, run_id, step, attrs) do
    updates = Map.take(attrs, [:status, :input, :output, :last_error])

    {count, _rows} =
      StepRun
      |> where(
        [step_run],
        step_run.run_id == ^run_id and step_run.step == ^step and step_run.status == "failed"
      )
      |> repo.update_all(set: Map.to_list(updates))

    case count do
      1 -> {:ok, get_step_run(repo, run_id, step)}
      _ -> :not_updated
    end
  end

  @spec duplicate_step_claim?(Ecto.Changeset.t()) :: boolean()
  defp duplicate_step_claim?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {field, {"has already been taken", opts}} when field in [:run_id, :step] ->
        Keyword.get(opts, :constraint) == :unique

      _other ->
        false
    end)
  end

  @spec update_step(module(), Ecto.UUID.t(), map()) ::
          {:ok, StepRun.t()} | {:error, Ecto.Changeset.t() | :not_found}
  defp update_step(repo, step_run_id, attrs) do
    case repo.get(StepRun, step_run_id) do
      %StepRun{} = step_run ->
        step_run
        |> StepRun.changeset(attrs)
        |> repo.update()

      nil ->
        {:error, :not_found}
    end
  end

  @spec serialize_step(step_identifier()) :: String.t()
  defp serialize_step(step) when is_atom(step), do: Atom.to_string(step)
  defp serialize_step(step) when is_binary(step), do: step
end
