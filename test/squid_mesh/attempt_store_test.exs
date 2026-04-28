defmodule SquidMesh.AttemptStoreTest do
  use ExUnit.Case

  alias SquidMesh.AttemptStore
  alias SquidMesh.Persistence.StepRun
  alias SquidMesh.TestSupport.FakeRepo

  setup_all do
    start_supervised!(FakeRepo)
    :ok
  end

  setup do
    FakeRepo.reset()
    :ok
  end

  test "records attempt history for a step run" do
    {:ok, step_run} =
      %StepRun{}
      |> StepRun.changeset(%{
        run_id: Ecto.UUID.generate(),
        step: "load_invoice",
        status: "running"
      })
      |> FakeRepo.insert()

    assert {:ok, attempt_one} =
             AttemptStore.record_attempt(FakeRepo, step_run.id, 1, "failed", %{
               error: %{message: "timeout"}
             })

    assert {:ok, attempt_two} =
             AttemptStore.record_attempt(FakeRepo, step_run.id, 2, "failed", %{
               error: %{message: "still failing"}
             })

    assert attempt_one.attempt_number == 1
    assert attempt_two.attempt_number == 2
    assert AttemptStore.attempt_count(FakeRepo, step_run.id) == 2

    assert AttemptStore.latest_attempt(FakeRepo, step_run.id).attempt_number == 2
  end
end
