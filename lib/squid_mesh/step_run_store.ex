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
  @type pause_target :: :complete | atom()
  @type approval_targets :: %{ok: pause_target(), error: pause_target()}
  @type manual_event :: map()
  @type step_status :: :pending | :running | :completed | :failed
  @type begin_result :: {:ok, StepRun.t(), :execute | :skip} | {:error, Ecto.Changeset.t()}
  @type schedule_result :: {:ok, StepRun.t(), :schedule | :skip} | {:error, Ecto.Changeset.t()}

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
      resume: nil,
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
  Persists that a step has been scheduled but not yet claimed by a worker.
  """
  @spec schedule_step(module(), Ecto.UUID.t(), step_identifier(), step_input()) ::
          schedule_result()
  def schedule_step(repo, run_id, step, input) when is_map(input) do
    serialized_step = serialize_step(step)

    attrs = %{
      id: Ecto.UUID.generate(),
      run_id: run_id,
      step: serialized_step,
      status: "pending",
      input: input,
      output: nil,
      resume: nil,
      last_error: nil,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    case repo.insert_all(
           StepRun,
           [attrs],
           on_conflict: :nothing,
           conflict_target: [:run_id, :step]
         ) do
      {1, _rows} ->
        {:ok, get_step_run(repo, run_id, serialized_step), :schedule}

      {0, _rows} ->
        case get_step_run(repo, run_id, serialized_step) do
          %StepRun{} = step_run -> {:ok, step_run, :skip}
          nil -> {:error, Ecto.Changeset.change(%StepRun{}, attrs)}
        end
    end
  end

  @doc """
  Marks a step run as completed and persists its output.
  """
  @spec complete_step(module(), Ecto.UUID.t(), step_output()) ::
          {:ok, StepRun.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def complete_step(repo, step_run_id, output) when is_map(output) do
    update_step(repo, step_run_id, %{
      status: "completed",
      output: output,
      manual: nil,
      resume: nil,
      last_error: nil
    })
  end

  @doc """
  Marks a paused manual step as completed, persists its output, and records the
  durable manual action metadata.
  """
  @spec complete_manual_step(module(), Ecto.UUID.t(), step_output(), manual_event()) ::
          {:ok, StepRun.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def complete_manual_step(repo, step_run_id, output, manual)
      when is_map(output) and is_map(manual) do
    update_step(repo, step_run_id, %{
      status: "completed",
      output: output,
      manual: manual,
      resume: nil,
      last_error: nil
    })
  end

  @doc """
  Marks a step run as failed and persists the last error.
  """
  @spec fail_step(module(), Ecto.UUID.t(), step_error()) ::
          {:ok, StepRun.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def fail_step(repo, step_run_id, error) when is_map(error) do
    update_step(repo, step_run_id, %{
      status: "failed",
      manual: nil,
      resume: nil,
      last_error: error
    })
  end

  @doc """
  Persists pause-resume metadata for a running pause step without completing it.
  """
  @spec persist_pause_resume(module(), Ecto.UUID.t(), step_output(), pause_target()) ::
          {:ok, StepRun.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def persist_pause_resume(repo, step_run_id, output, target)
      when is_map(output) and (target == :complete or is_atom(target)) do
    update_step(repo, step_run_id, %{
      resume: %{
        "output" => output,
        "target" => serialize_pause_target(target)
      }
    })
  end

  @doc """
  Persists approval resume metadata for a running approval step without
  completing it.
  """
  @spec persist_approval_resume(module(), Ecto.UUID.t(), approval_targets(), atom() | nil) ::
          {:ok, StepRun.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def persist_approval_resume(
        repo,
        step_run_id,
        %{ok: ok_target, error: error_target},
        output_key
      )
      when (ok_target == :complete or is_atom(ok_target)) and
             (error_target == :complete or is_atom(error_target)) and
             (is_atom(output_key) or is_nil(output_key)) do
    update_step(repo, step_run_id, %{
      resume: %{
        "kind" => "approval",
        "ok_target" => serialize_pause_target(ok_target),
        "error_target" => serialize_pause_target(error_target),
        "output_key" => serialize_output_key(output_key)
      }
    })
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

  @doc """
  Lists the completed step outputs for one workflow run in completion order.
  """
  @spec completed_outputs(module(), Ecto.UUID.t()) :: [step_output()]
  def completed_outputs(repo, run_id) do
    StepRun
    |> where([step_run], step_run.run_id == ^run_id and step_run.status == "completed")
    |> order_by([step_run], asc: step_run.inserted_at)
    |> select([step_run], step_run.output)
    |> repo.all()
    |> Enum.map(&Kernel.||(&1, %{}))
  end

  @doc """
  Lists the persisted step status for each declared step in a workflow run.
  """
  @spec step_statuses(module(), Ecto.UUID.t()) :: %{optional(String.t()) => step_status()}
  def step_statuses(repo, run_id) do
    StepRun
    |> where([step_run], step_run.run_id == ^run_id)
    |> select([step_run], {step_run.step, step_run.status})
    |> repo.all()
    |> Map.new(fn {step, status} -> {step, deserialize_status(status)} end)
  end

  @spec insert_step_run(module(), map()) :: {:ok, StepRun.t()} | {:error, Ecto.Changeset.t()}
  defp insert_step_run(repo, attrs) do
    %StepRun{}
    |> StepRun.changeset(attrs)
    |> repo.insert()
  end

  @spec claim_existing_step(module(), Ecto.UUID.t(), String.t(), map()) :: begin_result()
  defp claim_existing_step(repo, run_id, step, attrs) do
    case transition_pending_step_to_running(repo, run_id, step, attrs) do
      {:ok, %StepRun{} = step_run} ->
        {:ok, step_run, :execute}

      :not_updated ->
        case transition_failed_step_to_running(repo, run_id, step, attrs) do
          {:ok, %StepRun{} = step_run} ->
            {:ok, step_run, :execute}

          :not_updated ->
            case get_step_run(repo, run_id, step) do
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
  end

  @spec transition_pending_step_to_running(module(), Ecto.UUID.t(), String.t(), map()) ::
          {:ok, StepRun.t()} | :not_updated
  defp transition_pending_step_to_running(repo, run_id, step, attrs) do
    updates =
      attrs
      |> Map.take([:status, :output, :resume, :last_error])
      |> Map.put(:status, "running")
      |> Map.put(:updated_at, now_utc())

    {count, _rows} =
      StepRun
      |> where(
        [step_run],
        step_run.run_id == ^run_id and step_run.step == ^step and step_run.status == "pending"
      )
      |> repo.update_all(set: Map.to_list(updates))

    case count do
      1 -> {:ok, get_step_run(repo, run_id, step)}
      _ -> :not_updated
    end
  end

  @spec transition_failed_step_to_running(module(), Ecto.UUID.t(), String.t(), map()) ::
          {:ok, StepRun.t()} | :not_updated
  defp transition_failed_step_to_running(repo, run_id, step, attrs) do
    updates =
      attrs
      |> Map.take([:status, :input, :output, :resume, :last_error])
      |> Map.put(:updated_at, now_utc())

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

  @spec deserialize_status(String.t()) :: step_status()
  defp deserialize_status("pending"), do: :pending
  defp deserialize_status("running"), do: :running
  defp deserialize_status("completed"), do: :completed
  defp deserialize_status("failed"), do: :failed

  @spec serialize_pause_target(pause_target()) :: String.t()
  defp serialize_pause_target(:complete), do: "__complete__"
  defp serialize_pause_target(target) when is_atom(target), do: serialize_step(target)

  @spec serialize_output_key(atom() | nil) :: String.t() | nil
  defp serialize_output_key(nil), do: nil
  defp serialize_output_key(output_key), do: Atom.to_string(output_key)

  @spec serialize_step(step_identifier()) :: String.t()
  defp serialize_step(step) when is_atom(step), do: Atom.to_string(step)
  defp serialize_step(step) when is_binary(step), do: step

  defp now_utc do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end
end
