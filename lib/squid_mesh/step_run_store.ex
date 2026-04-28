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
    attrs = %{
      run_id: run_id,
      step: serialize_step(step),
      status: "running",
      input: input,
      output: nil,
      last_error: nil
    }

    case get_step_run(repo, run_id, step) do
      %StepRun{status: status} = step_run when status in ["running", "completed"] ->
        {:ok, step_run, :skip}

      %StepRun{} = step_run ->
        case step_run
             |> StepRun.changeset(attrs)
             |> repo.update() do
          {:ok, updated_step_run} -> {:ok, updated_step_run, :execute}
          {:error, changeset} -> {:error, changeset}
        end

      nil ->
        case %StepRun{}
             |> StepRun.changeset(attrs)
             |> repo.insert() do
          {:ok, step_run} -> {:ok, step_run, :execute}
          {:error, changeset} -> {:error, changeset}
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
