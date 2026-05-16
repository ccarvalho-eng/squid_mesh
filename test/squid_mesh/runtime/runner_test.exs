defmodule SquidMesh.Runtime.RunnerTest do
  use SquidMesh.DataCase

  alias SquidMesh.Executor.Payload
  alias SquidMesh.Persistence.Run, as: RunRecord
  alias SquidMesh.Runtime.Runner

  defmodule IdempotentCronWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :scheduled_digest do
        cron "0 9 * * *", timezone: "UTC", idempotency: :reuse_existing
      end

      step :deliver_digest, IdempotentCronWorkflow.DeliverDigest
    end
  end

  defmodule IdempotentCronWorkflow.DeliverDigest do
    use Jido.Action,
      name: "deliver_digest",
      description: "Delivers a scheduled digest",
      schema: []

    @impl true
    def run(_params, _context), do: {:ok, %{}}
  end

  defmodule NonIdempotentCronWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :scheduled_digest do
        cron "0 9 * * *", timezone: "UTC"
      end

      step :deliver_digest, NonIdempotentCronWorkflow.DeliverDigest
    end
  end

  defmodule NonIdempotentCronWorkflow.DeliverDigest do
    use Jido.Action,
      name: "deliver_digest",
      description: "Delivers a scheduled digest",
      schema: []

    @impl true
    def run(_params, _context), do: {:ok, %{}}
  end

  defmodule SkipIdempotentCronWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :scheduled_digest do
        cron "0 9 * * *", timezone: "UTC", idempotency: :skip
      end

      step :deliver_digest, SkipIdempotentCronWorkflow.DeliverDigest
    end
  end

  defmodule SkipIdempotentCronWorkflow.DeliverDigest do
    use Jido.Action,
      name: "deliver_digest",
      description: "Delivers a scheduled digest",
      schema: []

    @impl true
    def run(_params, _context), do: {:ok, %{}}
  end

  test "reuses an existing run for duplicate idempotent cron deliveries" do
    payload = cron_payload(IdempotentCronWorkflow)

    assert :ok = Runner.perform(payload)

    assert {:ok, {:duplicate_schedule_start, duplicate_run_id}} =
             Runner.start_cron_trigger(
               payload["workflow"],
               payload["trigger"],
               payload,
               []
             )

    assert [%RunRecord{id: run_id, context: context}] = Repo.all(RunRecord)
    assert duplicate_run_id == run_id
    assert get_in(context, ["schedule", "idempotency"]) == "reuse_existing"
    assert get_in(context, ["schedule", "idempotency_key"]) == "digest-2026-05-16T09"
  end

  test "surfaces duplicate cron delivery as skipped when configured" do
    payload = cron_payload(SkipIdempotentCronWorkflow)

    assert :ok = Runner.perform(payload)

    assert {:ok, {:skipped_schedule_start, skipped_run_id}} =
             Runner.start_cron_trigger(
               payload["workflow"],
               payload["trigger"],
               payload,
               []
             )

    assert [%RunRecord{id: run_id, context: context}] = Repo.all(RunRecord)
    assert skipped_run_id == run_id
    assert get_in(context, ["schedule", "idempotency"]) == "skip"
  end

  test "allows duplicate cron deliveries when idempotency is not enabled" do
    payload = cron_payload(NonIdempotentCronWorkflow)

    assert :ok = Runner.perform(payload)
    assert :ok = Runner.perform(payload)

    assert Repo.aggregate(RunRecord, :count) == 2
  end

  defp cron_payload(workflow) do
    Payload.cron(workflow, :scheduled_digest,
      signal_id: "digest-2026-05-16T09",
      intended_window: %{
        start_at: "2026-05-16T09:00:00Z",
        end_at: "2026-05-16T10:00:00Z"
      }
    )
  end
end
