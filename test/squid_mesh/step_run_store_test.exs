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
end
