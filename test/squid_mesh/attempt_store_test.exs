defmodule SquidMesh.AttemptStoreTest do
  use SquidMesh.DataCase

  alias SquidMesh.AttemptStore
  alias SquidMesh.Persistence.Run, as: RunRecord
  alias SquidMesh.Persistence.StepRun

  test "records attempt history for a step run" do
    {:ok, run} =
      %RunRecord{}
      |> RunRecord.changeset(%{
        workflow: "Elixir.SquidMesh.AttemptStoreTest.Workflow",
        status: "pending",
        input: %{}
      })
      |> Repo.insert()

    {:ok, step_run} =
      %StepRun{}
      |> StepRun.changeset(%{
        run_id: run.id,
        step: "load_invoice",
        status: "running"
      })
      |> Repo.insert()

    assert {:ok, attempt_one} =
             AttemptStore.record_attempt(Repo, step_run.id, 1, "failed", %{
               error: %{message: "timeout"}
             })

    assert {:ok, attempt_two} =
             AttemptStore.record_attempt(Repo, step_run.id, 2, "failed", %{
               error: %{message: "still failing"}
             })

    assert attempt_one.attempt_number == 1
    assert attempt_two.attempt_number == 2
    assert AttemptStore.attempt_count(Repo, step_run.id) == 2

    assert AttemptStore.latest_attempt(Repo, step_run.id).attempt_number == 2
  end
end
