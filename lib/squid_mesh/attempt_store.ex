defmodule SquidMesh.AttemptStore do
  @moduledoc false

  import Ecto.Query

  alias SquidMesh.Persistence.StepAttempt

  @type attempt_attrs :: %{optional(:error) => map() | nil}

  @spec record_attempt(module(), Ecto.UUID.t(), pos_integer(), String.t(), attempt_attrs()) ::
          {:ok, StepAttempt.t()} | {:error, Ecto.Changeset.t()}
  def record_attempt(repo, step_run_id, attempt_number, status, attrs \\ %{})
      when is_integer(attempt_number) and attempt_number > 0 and is_map(attrs) do
    attrs =
      attrs
      |> Map.take([:error])
      |> Map.merge(%{
        step_run_id: step_run_id,
        attempt_number: attempt_number,
        status: status
      })

    %StepAttempt{}
    |> StepAttempt.changeset(attrs)
    |> repo.insert()
  end

  @spec attempt_count(module(), Ecto.UUID.t()) :: non_neg_integer()
  def attempt_count(repo, step_run_id) do
    repo
    |> attempts_for(step_run_id)
    |> length()
  end

  @spec latest_attempt(module(), Ecto.UUID.t()) :: StepAttempt.t() | nil
  def latest_attempt(repo, step_run_id) do
    repo
    |> attempts_for(step_run_id)
    |> Enum.max_by(& &1.attempt_number, fn -> nil end)
  end

  defp attempts_for(repo, step_run_id) do
    if function_exported?(repo, :list_step_attempts, 1) do
      repo.list_step_attempts(step_run_id)
    else
      StepAttempt
      |> where([attempt], attempt.step_run_id == ^step_run_id)
      |> repo.all()
    end
  end
end
