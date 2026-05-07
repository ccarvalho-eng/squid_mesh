defmodule SquidMesh.ObservabilityTest do
  use SquidMesh.DataCase

  import ExUnit.CaptureLog

  alias SquidMesh.AttemptStore
  alias SquidMesh.Config
  alias SquidMesh.RunStore
  alias SquidMesh.Runtime.StepExecutor.Outcome
  alias SquidMesh.StepRunStore

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

  defmodule DispatchWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
        end
      end

      step(:prepare_invoice, DispatchWorkflow.PrepareInvoice)
      step(:deliver_invoice, DispatchWorkflow.DeliverInvoice)

      transition(:prepare_invoice, on: :ok, to: :deliver_invoice)
      transition(:deliver_invoice, on: :ok, to: :complete)
    end
  end

  defmodule DispatchWorkflow.PrepareInvoice do
    use Jido.Action,
      name: "prepare_invoice",
      description: "Prepares an invoice",
      schema: [account_id: [type: :string, required: true]]

    @impl true
    def run(%{account_id: account_id}, _context) do
      {:ok, %{invoice: %{account_id: account_id}}}
    end
  end

  defmodule DispatchWorkflow.DeliverInvoice do
    use Jido.Action,
      name: "deliver_invoice",
      description: "Delivers an invoice",
      schema: [invoice: [type: :map, required: true]]

    @impl true
    def run(%{invoice: invoice}, _context) do
      {:ok, %{delivery: %{account_id: invoice.account_id, status: "sent"}}}
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

  defmodule MissingOban do
  end

  defmodule PauseWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
        end
      end

      step(:wait_for_approval, :pause)
      step(:record_delivery, :log, message: "delivery recorded", level: :info)

      transition(:wait_for_approval, on: :ok, to: :record_delivery)
      transition(:record_delivery, on: :ok, to: :complete)
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

  test "emits outcome telemetry after the outcome transaction commits" do
    handler_id = "squid-mesh-outcome-transaction-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:squid_mesh, :run, :transition],
          [:squid_mesh, :run, :dispatched],
          [:squid_mesh, :step, :completed],
          [:squid_mesh, :step, :failed],
          [:squid_mesh, :step, :retry_scheduled]
        ],
        fn event, _measurements, _metadata, pid ->
          send(pid, {:outcome_tx_event, event, Repo.in_transaction?()})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, config} = Config.load(repo: Repo)
    assert {:ok, definition} = SquidMesh.Workflow.Definition.load(SuccessfulWorkflow)
    assert {:ok, run} = RunStore.create_run(Repo, SuccessfulWorkflow, %{account_id: "acct_123"})

    assert {:ok, running_run} =
             RunStore.transition_run(Repo, run.id, :running, %{current_step: :deliver_invoice})

    assert {:ok, step_run, :execute} =
             StepRunStore.begin_step(Repo, run.id, :deliver_invoice, %{account_id: "acct_123"})

    assert {:ok, attempt} = AttemptStore.begin_attempt(Repo, step_run.id)

    flush_telemetry_events()
    flush_outcome_tx_events()

    assert :ok =
             Outcome.apply_execution_result(
               {:ok, %{delivery: %{account_id: "acct_123", status: "sent"}}, []},
               config,
               definition,
               running_run,
               :deliver_invoice,
               step_run.id,
               attempt.id,
               attempt.attempt_number,
               System.monotonic_time()
             )

    assert_receive {:outcome_tx_event, [:squid_mesh, :step, :completed], false}
    assert_receive {:outcome_tx_event, [:squid_mesh, :run, :transition], false}
    refute_receive {:outcome_tx_event, _event, true}
  end

  test "emits successor dispatch telemetry after the outcome transaction commits" do
    handler_id = "squid-mesh-outcome-dispatch-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:squid_mesh, :run, :dispatched], [:squid_mesh, :step, :completed]],
        fn event, _measurements, _metadata, pid ->
          send(pid, {:outcome_dispatch_event, event, Repo.in_transaction?()})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, config} = Config.load(repo: Repo)
    assert {:ok, definition} = SquidMesh.Workflow.Definition.load(DispatchWorkflow)
    assert {:ok, run} = RunStore.create_run(Repo, DispatchWorkflow, %{account_id: "acct_123"})

    assert {:ok, running_run} =
             RunStore.transition_run(Repo, run.id, :running, %{current_step: :prepare_invoice})

    assert {:ok, step_run, :execute} =
             StepRunStore.begin_step(Repo, run.id, :prepare_invoice, %{account_id: "acct_123"})

    assert {:ok, attempt} = AttemptStore.begin_attempt(Repo, step_run.id)

    flush_telemetry_events()
    flush_outcome_dispatch_events()

    assert :ok =
             Outcome.apply_execution_result(
               {:ok, %{invoice: %{account_id: "acct_123"}}, []},
               config,
               definition,
               running_run,
               :prepare_invoice,
               step_run.id,
               attempt.id,
               attempt.attempt_number,
               System.monotonic_time()
             )

    assert_receive {:outcome_dispatch_event, [:squid_mesh, :step, :completed], false}
    assert_receive {:outcome_dispatch_event, [:squid_mesh, :run, :dispatched], false}
    refute_receive {:outcome_dispatch_event, _event, true}
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

  test "does not emit retry scheduled telemetry when retry dispatch fails" do
    assert {:ok, config} = Config.load(repo: Repo, execution: [name: MissingOban])
    assert {:ok, definition} = SquidMesh.Workflow.Definition.load(RetryWorkflow)
    assert {:ok, run} = RunStore.create_run(Repo, RetryWorkflow, %{account_id: "acct_123"})

    assert {:ok, running_run} =
             RunStore.transition_run(Repo, run.id, :running, %{current_step: :check_gateway})

    assert {:ok, step_run, :execute} =
             StepRunStore.begin_step(Repo, run.id, :check_gateway, %{account_id: "acct_123"})

    assert {:ok, attempt} = AttemptStore.begin_attempt(Repo, step_run.id)

    flush_telemetry_events()

    assert :ok =
             Outcome.apply_execution_result(
               {:error, %{message: "gateway timeout", code: "gateway_timeout"}},
               config,
               definition,
               running_run,
               :check_gateway,
               step_run.id,
               attempt.id,
               attempt.attempt_number,
               System.monotonic_time()
             )

    refute_receive {:telemetry_event, [:squid_mesh, :step, :retry_scheduled], _measurements,
                    _metadata},
                   50

    assert {:ok, failed_run} = SquidMesh.inspect_run(run.id, repo: Repo)
    assert failed_run.status == :failed
    assert failed_run.last_error.message == "failed to dispatch workflow step"
  end

  test "emits step completion telemetry when a paused step is unblocked" do
    assert {:ok, run} = SquidMesh.start_run(PauseWorkflow, %{account_id: "acct_123"}, repo: Repo)

    assert :ok =
             SquidMesh.Workers.StepWorker.perform(%Oban.Job{
               args: %{"run_id" => run.id, "step" => "wait_for_approval"}
             })

    assert {:ok, paused_run} = SquidMesh.inspect_run(run.id, repo: Repo)
    assert paused_run.status == :paused

    flush_telemetry_events()

    assert {:ok, resumed_run} = SquidMesh.unblock_run(run.id, repo: Repo)
    assert resumed_run.status == :running

    assert_receive {:telemetry_event, [:squid_mesh, :step, :completed],
                    %{duration: duration, system_time: _}, metadata}

    assert duration >= 0
    assert metadata.run_id == run.id
    assert metadata.workflow == PauseWorkflow
    assert metadata.step == :wait_for_approval
    assert metadata.attempt == 1

    assert_receive {:telemetry_event, [:squid_mesh, :run, :transition], %{system_time: _},
                    transition_metadata}

    assert transition_metadata.run_id == run.id
    assert transition_metadata.from_status == :paused
    assert transition_metadata.to_status == :running

    assert_receive {:telemetry_event, [:squid_mesh, :run, :dispatched], %{system_time: _},
                    dispatch_metadata}

    assert dispatch_metadata.run_id == run.id
  end

  test "emits step failure telemetry when a paused run is cancelled" do
    assert {:ok, run} = SquidMesh.start_run(PauseWorkflow, %{account_id: "acct_123"}, repo: Repo)

    assert :ok =
             SquidMesh.Workers.StepWorker.perform(%Oban.Job{
               args: %{"run_id" => run.id, "step" => "wait_for_approval"}
             })

    assert {:ok, paused_run} = SquidMesh.inspect_run(run.id, repo: Repo)
    assert paused_run.status == :paused

    assert {:ok, cancelled_run} = SquidMesh.cancel_run(run.id, repo: Repo)
    assert cancelled_run.status == :cancelled

    assert_receive {:telemetry_event, [:squid_mesh, :step, :failed],
                    %{duration: duration, system_time: _}, metadata}

    assert duration >= 0
    assert metadata.run_id == run.id
    assert metadata.workflow == PauseWorkflow
    assert metadata.step == :wait_for_approval
    assert metadata.attempt == 1
    assert metadata.error == %{message: "run cancelled while paused", reason: "cancelled"}
  end

  test "emits paused step failure before the cancelled run transition when cancellation wins during pause progression" do
    assert {:ok, config} = Config.load(repo: Repo)
    assert {:ok, definition} = SquidMesh.Workflow.Definition.load(PauseWorkflow)
    assert {:ok, run} = RunStore.create_run(Repo, PauseWorkflow, %{account_id: "acct_123"})

    assert {:ok, running_run} =
             RunStore.transition_run(Repo, run.id, :running, %{current_step: :wait_for_approval})

    assert {:ok, step_run, :execute} =
             StepRunStore.begin_step(Repo, run.id, :wait_for_approval, %{account_id: "acct_123"})

    assert {:ok, attempt} = AttemptStore.begin_attempt(Repo, step_run.id)
    assert {:ok, cancelling_run} = SquidMesh.cancel_run(run.id, repo: Repo)
    assert cancelling_run.status == :cancelling

    flush_telemetry_events()

    assert :ok =
             Outcome.apply_execution_result(
               {:ok, %{}, [pause: true]},
               config,
               definition,
               running_run,
               :wait_for_approval,
               step_run.id,
               attempt.id,
               attempt.attempt_number,
               System.monotonic_time()
             )

    assert_receive {:telemetry_event, [:squid_mesh, :step, :failed],
                    %{duration: duration, system_time: _}, metadata}

    assert duration >= 0
    assert metadata.run_id == run.id
    assert metadata.step == :wait_for_approval
    assert metadata.attempt == 1
    assert metadata.error == %{message: "run cancelled while paused", reason: "cancelled"}

    assert_receive {:telemetry_event, [:squid_mesh, :run, :transition], %{system_time: _},
                    transition_metadata}

    assert transition_metadata.run_id == run.id
    assert transition_metadata.from_status == :cancelling
    assert transition_metadata.to_status == :cancelled
  end

  defp flush_telemetry_events do
    receive do
      {:telemetry_event, _event, _measurements, _metadata} -> flush_telemetry_events()
    after
      0 -> :ok
    end
  end

  defp flush_outcome_tx_events do
    receive do
      {:outcome_tx_event, _event, _in_transaction?} -> flush_outcome_tx_events()
    after
      0 -> :ok
    end
  end

  defp flush_outcome_dispatch_events do
    receive do
      {:outcome_dispatch_event, _event, _in_transaction?} -> flush_outcome_dispatch_events()
    after
      0 -> :ok
    end
  end
end
