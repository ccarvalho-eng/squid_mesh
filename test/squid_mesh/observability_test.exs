defmodule SquidMesh.ObservabilityTest do
  use SquidMesh.DataCase

  import ExUnit.CaptureLog

  @events [
    [:squid_mesh, :run, :created],
    [:squid_mesh, :run, :replayed],
    [:squid_mesh, :run, :dispatched],
    [:squid_mesh, :run, :transition],
    [:squid_mesh, :step, :started],
    [:squid_mesh, :step, :skipped],
    [:squid_mesh, :step, :completed],
    [:squid_mesh, :step, :failed],
    [:squid_mesh, :step, :retry_scheduled]
  ]

  defmodule SuccessfulWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
        end
      end

      step(:deliver_invoice, SuccessfulWorkflow.DeliverInvoice)
      transition(:deliver_invoice, on: :ok, to: :complete)
    end
  end

  defmodule SuccessfulWorkflow.DeliverInvoice do
    use Jido.Action,
      name: "deliver_invoice",
      description: "Delivers an invoice",
      schema: [account_id: [type: :string, required: true]]

    @impl true
    def run(%{account_id: account_id}, _context) do
      {:ok, %{delivery: %{account_id: account_id, status: "sent"}}}
    end
  end

  defmodule RetryWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
        end
      end

      step(:check_gateway, RetryWorkflow.CheckGateway,
        retry: [max_attempts: 2, backoff: [type: :exponential, min: 1_000, max: 1_000]]
      )

      transition(:check_gateway, on: :ok, to: :complete)
    end
  end

  defmodule RetryWorkflow.CheckGateway do
    use Jido.Action,
      name: "check_gateway",
      description: "Fails once and retries",
      schema: [account_id: [type: :string, required: true]]

    @impl true
    def run(_params, _context) do
      {:error, %{message: "gateway timeout", code: "gateway_timeout"}}
    end
  end

  setup do
    handler_id = "squid-mesh-observability-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        @events,
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry_event, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "emits run creation, dispatch, transition, and successful step events" do
    assert {:ok, run} =
             SquidMesh.start_run(SuccessfulWorkflow, %{account_id: "acct_123"}, repo: Repo)

    assert_receive {:telemetry_event, [:squid_mesh, :run, :created], %{system_time: system_time},
                    metadata}

    assert is_integer(system_time)
    assert metadata.run_id == run.id
    assert metadata.workflow == SuccessfulWorkflow
    assert metadata.trigger == :manual
    assert metadata.current_step == :deliver_invoice

    assert_receive {:telemetry_event, [:squid_mesh, :run, :dispatched], %{system_time: _},
                    metadata}

    assert metadata.run_id == run.id
    assert metadata.queue == :squid_mesh
    assert metadata.schedule_in == nil

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :squid_mesh)

    assert_receive {:telemetry_event, [:squid_mesh, :run, :transition], %{system_time: _},
                    metadata}

    assert metadata.run_id == run.id
    assert metadata.from_status == :pending
    assert metadata.to_status == :running

    assert_receive {:telemetry_event, [:squid_mesh, :step, :started], %{system_time: _}, metadata}
    assert metadata.run_id == run.id
    assert metadata.workflow == SuccessfulWorkflow
    assert metadata.step == :deliver_invoice
    assert metadata.attempt == 1

    assert_receive {:telemetry_event, [:squid_mesh, :step, :completed],
                    %{duration: duration, system_time: _}, metadata}

    assert duration > 0
    assert metadata.run_id == run.id
    assert metadata.step == :deliver_invoice
    assert metadata.attempt == 1

    assert_receive {:telemetry_event, [:squid_mesh, :run, :transition], %{system_time: _},
                    metadata}

    assert metadata.run_id == run.id
    assert metadata.from_status == :running
    assert metadata.to_status == :completed
  end

  test "emits retry telemetry and logs workflow metadata on failure" do
    assert {:ok, run} = SquidMesh.start_run(RetryWorkflow, %{account_id: "acct_123"}, repo: Repo)

    log =
      capture_log([metadata: [:run_id, :workflow, :step, :attempt]], fn ->
        assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :squid_mesh)
      end)

    assert_receive {:telemetry_event, [:squid_mesh, :step, :failed],
                    %{duration: duration, system_time: _}, metadata}

    assert duration > 0
    assert metadata.run_id == run.id
    assert metadata.workflow == RetryWorkflow
    assert metadata.step == :check_gateway
    assert metadata.attempt == 1
    assert metadata.error == %{message: "gateway timeout", code: "gateway_timeout"}

    assert_receive {:telemetry_event, [:squid_mesh, :step, :retry_scheduled],
                    %{delay_ms: 1000, system_time: _}, metadata}

    assert metadata.run_id == run.id
    assert metadata.step == :check_gateway
    assert metadata.attempt == 1

    assert_receive {:telemetry_event, [:squid_mesh, :run, :transition], %{system_time: _},
                    metadata}

    assert metadata.run_id == run.id
    assert metadata.from_status == :pending
    assert metadata.to_status == :running

    assert_receive {:telemetry_event, [:squid_mesh, :run, :transition], %{system_time: _},
                    metadata}

    assert metadata.run_id == run.id
    assert metadata.from_status == :running
    assert metadata.to_status == :retrying

    assert log =~ "workflow step failed; scheduling retry"
    assert log =~ "run_id=#{run.id}"
    assert log =~ "workflow=SquidMesh.ObservabilityTest.RetryWorkflow"
    assert log =~ "step=check_gateway"
    assert log =~ "attempt=1"
  end
end
