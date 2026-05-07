defmodule SquidMesh.StepRunStoreTest do
  use SquidMesh.DataCase

  alias SquidMesh.Persistence.Run, as: RunRecord
  alias SquidMesh.StepRunStore

  test "claims a step once and skips concurrent duplicate claims" do
    {:ok, run} =
      %RunRecord{}
      |> RunRecord.changeset(%{
        workflow: "Elixir.SquidMesh.StepRunStoreTest.Workflow",
        trigger: "manual",
        status: "running",
        input: %{}
      })
      |> Repo.insert()

    results =
      1..4
      |> Task.async_stream(
        fn _ ->
          StepRunStore.begin_step(Repo, run.id, :load_invoice, %{account_id: "acct_123"})
        end,
        max_concurrency: 4,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, fn
             {:ok, _step_run, :execute} -> true
             _other -> false
           end) == 1

    assert Enum.count(results, fn
             {:ok, _step_run, :skip} -> true
             _other -> false
           end) == 3
  end

  test "claims a scheduled step and skips duplicate schedules" do
    {:ok, run} =
      %RunRecord{}
      |> RunRecord.changeset(%{
        workflow: "Elixir.SquidMesh.StepRunStoreTest.Workflow",
        trigger: "manual",
        status: "running",
        input: %{}
      })
      |> Repo.insert()

    assert {:ok, scheduled_step_run, :schedule} =
             StepRunStore.schedule_step(Repo, run.id, :load_invoice, %{account_id: "acct_123"})

    assert scheduled_step_run.status == "pending"

    Process.sleep(1)

    assert {:ok, duplicate_schedule, :skip} =
             StepRunStore.schedule_step(Repo, run.id, :load_invoice, %{account_id: "acct_123"})

    assert duplicate_schedule.id == scheduled_step_run.id
    assert duplicate_schedule.status == "pending"

    assert {:ok, claimed_step_run, :execute} =
             StepRunStore.begin_step(Repo, run.id, :load_invoice, %{account_id: "acct_123"})

    assert claimed_step_run.id == scheduled_step_run.id
    assert claimed_step_run.status == "running"
    assert DateTime.compare(claimed_step_run.updated_at, scheduled_step_run.updated_at) == :gt

    assert {:ok, duplicate_claim, :skip} =
             StepRunStore.begin_step(Repo, run.id, :load_invoice, %{account_id: "acct_123"})

    assert duplicate_claim.id == scheduled_step_run.id
    assert duplicate_claim.status == "running"
  end

  test "rejects stale terminal updates after a step is finalized" do
    {:ok, run} =
      %RunRecord{}
      |> RunRecord.changeset(%{
        workflow: "Elixir.SquidMesh.StepRunStoreTest.Workflow",
        trigger: "manual",
        status: "running",
        input: %{}
      })
      |> Repo.insert()

    assert {:ok, step_run, :execute} =
             StepRunStore.begin_step(Repo, run.id, :load_invoice, %{account_id: "acct_123"})

    assert {:ok, completed_step} =
             StepRunStore.complete_step(Repo, step_run.id, %{invoice: %{id: "inv_456"}})

    assert completed_step.status == "completed"

    assert {:error, {:stale_step_run, "completed"}} =
             StepRunStore.fail_step(Repo, step_run.id, %{message: "late failure"})

    assert {:error, {:stale_step_run, "completed"}} =
             StepRunStore.complete_step(Repo, step_run.id, %{invoice: %{id: "inv_999"}})

    assert Repo.get!(SquidMesh.Persistence.StepRun, step_run.id).output == %{
             "invoice" => %{"id" => "inv_456"}
           }
  end
end
