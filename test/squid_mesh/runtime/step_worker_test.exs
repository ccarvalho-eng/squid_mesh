defmodule SquidMesh.Runtime.StepWorkerTest do
  use SquidMesh.DataCase

  import Ecto.Query

  alias __MODULE__.BackoffWorkflow
  alias __MODULE__.BuiltInWorkflow
  alias __MODULE__.CancellationCompletionWorkflow
  alias __MODULE__.ConcurrentDependencyFailureWorkflow
  alias __MODULE__.ConcurrentDependencyWorkflow
  alias __MODULE__.ConcurrentRetryWorkflow
  alias __MODULE__.DependencyFailureWorkflow
  alias __MODULE__.DependencyWorkflow
  alias __MODULE__.ErrorRoutingWorkflow
  alias __MODULE__.ExplicitMappingWorkflow
  alias __MODULE__.ExhaustedRetryWorkflow
  alias __MODULE__.FailingWorkflow
  alias __MODULE__.InputIsolationWorkflow
  alias __MODULE__.MissingOban
  alias __MODULE__.OrderedDependencyWorkflow
  alias __MODULE__.PauseMappedWorkflow
  alias __MODULE__.PauseWorkflow
  alias __MODULE__.RetrySurfaceWorkflow
  alias __MODULE__.SuccessfulWorkflow

  alias SquidMesh.AttemptStore
  alias SquidMesh.Config
  alias SquidMesh.Persistence.StepRun
  alias SquidMesh.Runtime.StepExecutor
  alias SquidMesh.Runtime.StepExecutor.Outcome
  alias SquidMesh.StepRunStore
  alias SquidMesh.Workers.StepWorker
  alias Oban.Job

  describe "workflow execution through Oban" do
    test "enqueues and executes the declared steps through Jido-backed actions" do
      input = %{account_id: "acct_123", invoice_id: "inv_456"}

      assert {:ok, run} = SquidMesh.start_run(SuccessfulWorkflow, input, repo: Repo)

      assert_enqueued(
        worker: SquidMesh.Workers.StepWorker,
        queue: "squid_mesh",
        args: %{"run_id" => run.id, "step" => "load_invoice"}
      )

      assert %{success: 2, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      assert {:ok, completed_run} = SquidMesh.inspect_run(run.id, repo: Repo)

      assert completed_run.status == :completed
      assert completed_run.current_step == nil
      assert completed_run.last_error == nil
      assert completed_run.context.account == %{id: "acct_123"}
      assert completed_run.context.invoice == %{id: "inv_456", status: "open"}

      assert completed_run.context.delivery == %{
               account_id: "acct_123",
               invoice_id: "inv_456",
               channel: "email"
             }

      step_runs =
        Repo.all(
          from(step_run in StepRun,
            where: step_run.run_id == ^run.id,
            order_by: [asc: step_run.inserted_at]
          )
        )

      assert Enum.map(step_runs, &{&1.step, &1.status}) == [
               {"load_invoice", "completed"},
               {"send_email", "completed"}
             ]

      assert Enum.map(step_runs, &AttemptStore.attempt_count(Repo, &1.id)) == [1, 1]
    end

    test "holds a join step until all declared dependencies complete" do
      input = %{account_id: "acct_123", invoice_id: "inv_456"}

      assert {:ok, run} = SquidMesh.start_run(DependencyWorkflow, input, repo: Repo)
      assert run.current_step == nil

      assert 2 ==
               Repo.aggregate(
                 from(job in Job,
                   where:
                     job.worker == "SquidMesh.Workers.StepWorker" and
                       job.state == "available" and
                       fragment("?->>'run_id' = ?", job.args, ^run.id)
                 ),
                 :count
               )

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "load_account"}
               })

      assert {:ok, running_run} = SquidMesh.inspect_run(run.id, repo: Repo)
      assert running_run.status == :running
      assert running_run.current_step == nil
      assert running_run.context.account == %{id: "acct_123", tier: "pro"}
      refute Map.has_key?(running_run.context, :delivery)

      assert 1 ==
               Repo.aggregate(
                 from(job in Job,
                   where:
                     job.worker == "SquidMesh.Workers.StepWorker" and
                       job.state == "available" and
                       fragment("?->>'run_id' = ?", job.args, ^run.id) and
                       fragment("?->>'step' = 'load_invoice'", job.args)
                 ),
                 :count
               )

      assert 0 ==
               Repo.aggregate(
                 from(job in Job,
                   where:
                     job.worker == "SquidMesh.Workers.StepWorker" and
                       job.state == "available" and
                       fragment("?->>'run_id' = ?", job.args, ^run.id) and
                       fragment("?->>'step' = 'send_email'", job.args)
                 ),
                 :count
               )

      assert %{success: 3, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      assert {:ok, completed_run} = SquidMesh.inspect_run(run.id, repo: Repo)

      assert completed_run.status == :completed
      assert completed_run.current_step == nil
      assert completed_run.context.account == %{id: "acct_123", tier: "pro"}
      assert completed_run.context.invoice == %{id: "inv_456", status: "open"}

      assert completed_run.context.delivery == %{
               account_id: "acct_123",
               invoice_id: "inv_456",
               channel: "email"
             }

      step_runs =
        Repo.all(
          from(step_run in StepRun,
            where: step_run.run_id == ^run.id,
            order_by: [asc: step_run.inserted_at]
          )
        )

      assert Enum.map(step_runs, &{&1.step, &1.status}) == [
               {"load_account", "completed"},
               {"load_invoice", "completed"},
               {"send_email", "completed"}
             ]
    end

    test "includes graph-aware step inspection for dependency runs with history enabled" do
      input = %{account_id: "acct_123", invoice_id: "inv_456"}

      assert {:ok, run} = SquidMesh.start_run(DependencyWorkflow, input, repo: Repo)

      assert {:ok, pending_run} =
               SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)

      assert Enum.map(pending_run.steps, &{&1.step, &1.status, &1.depends_on}) == [
               {:load_account, :pending, []},
               {:load_invoice, :pending, []},
               {:send_email, :waiting, [:load_account, :load_invoice]}
             ]

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "load_account"}
               })

      assert {:ok, running_run} =
               SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)

      assert Enum.map(running_run.steps, &{&1.step, &1.status, &1.depends_on}) == [
               {:load_account, :completed, []},
               {:load_invoice, :pending, []},
               {:send_email, :waiting, [:load_account, :load_invoice]}
             ]

      completed_account_step = Enum.find(running_run.steps, &(&1.step == :load_account))
      assert completed_account_step.output == %{account: %{id: "acct_123", tier: "pro"}}
      assert Enum.map(completed_account_step.attempts, & &1.attempt_number) == [1]
    end

    test "skips stale dependency jobs for steps that were never scheduled" do
      input = %{account_id: "acct_123", invoice_id: "inv_456"}

      assert {:ok, run} = SquidMesh.start_run(DependencyWorkflow, input, repo: Repo)

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "send_email"}
               })

      assert {:ok, pending_run} = SquidMesh.inspect_run(run.id, repo: Repo)
      assert pending_run.status == :pending
      assert pending_run.current_step == nil
      assert pending_run.context == %{}

      assert nil ==
               Repo.one(
                 from(step_run in StepRun,
                   where: step_run.run_id == ^run.id and step_run.step == "send_email"
                 )
               )

      assert 2 ==
               Repo.aggregate(
                 from(job in Job,
                   where:
                     job.worker == "SquidMesh.Workers.StepWorker" and
                       job.state == "available" and
                       fragment("?->>'run_id' = ?", job.args, ^run.id)
                 ),
                 :count
               )
    end

    test "does not run a dependency join step when one prerequisite fails" do
      input = %{account_id: "acct_123", invoice_id: "inv_456"}

      assert {:ok, run} = SquidMesh.start_run(DependencyFailureWorkflow, input, repo: Repo)

      assert %{success: 2, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      assert {:ok, failed_run} = SquidMesh.inspect_run(run.id, repo: Repo)
      assert failed_run.status == :failed
      assert failed_run.current_step == :load_invoice
      assert failed_run.context.account == %{id: "acct_123", tier: "pro"}

      refute Map.has_key?(failed_run.context, :invoice)
      refute Map.has_key?(failed_run.context, :delivery)

      step_runs =
        Repo.all(
          from(step_run in StepRun,
            where: step_run.run_id == ^run.id,
            order_by: [asc: step_run.inserted_at]
          )
        )

      assert Enum.map(step_runs, &{&1.step, &1.status}) == [
               {"load_account", "completed"},
               {"load_invoice", "failed"}
             ]
    end

    test "runs remaining root steps before newly unlocked dependent steps" do
      input = %{account_id: "acct_123", invoice_id: "inv_456"}

      assert {:ok, run} = SquidMesh.start_run(OrderedDependencyWorkflow, input, repo: Repo)
      assert run.current_step == nil

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "load_account"}
               })

      assert {:ok, running_run} = SquidMesh.inspect_run(run.id, repo: Repo)
      assert running_run.current_step == nil
      refute Map.has_key?(running_run.context, :account_message)

      assert 1 ==
               Repo.aggregate(
                 from(job in Job,
                   where:
                     job.worker == "SquidMesh.Workers.StepWorker" and
                       job.state == "available" and
                       fragment("?->>'run_id' = ?", job.args, ^run.id) and
                       fragment("?->>'step' = 'load_invoice'", job.args)
                 ),
                 :count
               )

      assert 0 ==
               Repo.aggregate(
                 from(job in Job,
                   where:
                     job.worker == "SquidMesh.Workers.StepWorker" and
                       job.state == "available" and
                       fragment("?->>'run_id' = ?", job.args, ^run.id) and
                       fragment("?->>'step' = 'prepare_account_message'", job.args)
                 ),
                 :count
               )

      assert %{success: 4, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      assert {:ok, completed_run} = SquidMesh.inspect_run(run.id, repo: Repo)

      assert completed_run.status == :completed

      assert completed_run.context.account_message == %{
               account_id: "acct_123",
               status: "prepared"
             }
    end

    test "executes already scheduled dependency steps with their persisted input snapshot" do
      input = %{account_id: "acct_123", invoice_id: "inv_456"}

      assert {:ok, run} = SquidMesh.start_run(InputIsolationWorkflow, input, repo: Repo)

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "load_account"}
               })

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "load_invoice"}
               })

      assert %{success: success, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      assert success >= 1

      assert {:ok, completed_run} = SquidMesh.inspect_run(run.id, repo: Repo)

      assert completed_run.status == :completed
      assert completed_run.context.invoice.account_present? == false
    end

    test "supports explicit step input selection and output namespacing" do
      input = %{account_id: "acct_123", invoice_id: "inv_456"}

      assert {:ok, run} = SquidMesh.start_run(ExplicitMappingWorkflow, input, repo: Repo)

      assert %{success: 2, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      assert {:ok, completed_run} =
               SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)

      assert completed_run.status == :completed
      assert completed_run.context.account == %{id: "acct_123"}

      assert completed_run.context.delivery == %{
               account_id: "acct_123",
               invoice_id: "inv_456"
             }

      assert Enum.map(completed_run.step_runs, &{&1.step, &1.input, &1.output}) == [
               {:load_account, %{account_id: "acct_123"}, %{account: %{id: "acct_123"}}},
               {:record_delivery, %{account: %{id: "acct_123"}, invoice_id: "inv_456"},
                %{delivery: %{account_id: "acct_123", invoice_id: "inv_456"}}}
             ]

      assert Enum.map(completed_run.steps, &{&1.step, &1.status, &1.depends_on}) == [
               {:load_account, :completed, []},
               {:record_delivery, :completed, []}
             ]

      assert Enum.map(completed_run.steps, &{&1.step, &1.input, &1.output}) == [
               {:load_account, %{account_id: "acct_123"}, %{account: %{id: "acct_123"}}},
               {:record_delivery, %{account: %{id: "acct_123"}, invoice_id: "inv_456"},
                %{delivery: %{account_id: "acct_123", invoice_id: "inv_456"}}}
             ]
    end

    test "pauses a run at a built-in pause step until explicitly unblocked" do
      input = %{account_id: "acct_123"}

      assert {:ok, run} = SquidMesh.start_run(PauseWorkflow, input, repo: Repo)

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "wait_for_approval"}
               })

      assert {:ok, paused_run} =
               SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)

      assert paused_run.status == :paused
      assert paused_run.current_step == :wait_for_approval
      assert paused_run.last_error == nil

      assert 0 ==
               Repo.aggregate(
                 from(job in Job,
                   where:
                     job.worker == "SquidMesh.Workers.StepWorker" and
                       job.state == "available" and
                       fragment("?->>'run_id' = ?", job.args, ^run.id) and
                       fragment("?->>'step' = 'record_delivery'", job.args)
                 ),
                 :count
               )

      assert [%SquidMesh.StepRun{} = paused_step] = paused_run.step_runs
      assert paused_step.step == :wait_for_approval
      assert paused_step.status == :running
      assert paused_step.output == nil
      assert [%SquidMesh.StepAttempt{attempt_number: 1, status: :running}] = paused_step.attempts

      assert {:ok, unblocked_run} = SquidMesh.unblock_run(run.id, repo: Repo)
      assert unblocked_run.status == :running
      assert unblocked_run.current_step == :record_delivery

      assert %{success: success, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      assert success >= 1

      assert {:ok, completed_run} =
               SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)

      assert completed_run.status == :completed
      assert completed_run.current_step == nil

      assert Enum.map(completed_run.step_runs, &{&1.step, &1.status}) == [
               {:wait_for_approval, :completed},
               {:record_delivery, :completed}
             ]
    end

    test "persists pause output mappings after unblock" do
      assert {:ok, run} =
               SquidMesh.start_run(PauseMappedWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "wait_for_approval"}
               })

      assert {:ok, paused_run} =
               SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)

      assert paused_run.status == :paused

      assert {:ok, unblocked_run} = SquidMesh.unblock_run(run.id, repo: Repo)
      assert unblocked_run.status == :running

      assert %{success: success, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      assert success >= 1

      assert {:ok, completed_run} =
               SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)

      assert completed_run.status == :completed
      assert completed_run.context.approval == %{}
      assert completed_run.context.delivery == %{account_id: "acct_123", approval: %{}}

      assert Enum.map(completed_run.step_runs, &{&1.step, &1.output}) == [
               {:wait_for_approval, %{approval: %{}}},
               {:record_delivery, %{delivery: %{account_id: "acct_123", approval: %{}}}}
             ]
    end

    test "allows parallel root workers to start from a pending dependency run" do
      :persistent_term.put({ConcurrentDependencyWorkflow, :test_pid}, self())

      on_exit(fn ->
        :persistent_term.erase({ConcurrentDependencyWorkflow, :test_pid})
      end)

      input = %{account_id: "acct_123", invoice_id: "inv_456"}

      assert {:ok, run} = SquidMesh.start_run(ConcurrentDependencyWorkflow, input, repo: Repo)

      account_task =
        Task.async(fn ->
          StepWorker.perform(%Job{
            args: %{"run_id" => run.id, "step" => "load_account"}
          })
        end)

      invoice_task =
        Task.async(fn ->
          StepWorker.perform(%Job{
            args: %{"run_id" => run.id, "step" => "load_invoice"}
          })
        end)

      assert_receive {:concurrent_root_started, :load_account, account_pid}
      assert_receive {:concurrent_root_started, :load_invoice, invoice_pid}

      send(account_pid, :continue)
      send(invoice_pid, :continue)

      assert :ok = Task.await(account_task)
      assert :ok = Task.await(invoice_task)

      assert %{success: success, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      assert success >= 1

      assert {:ok, completed_run} = SquidMesh.inspect_run(run.id, repo: Repo)
      assert completed_run.status == :completed
      assert completed_run.context.account == %{id: "acct_123", tier: "pro"}
      assert completed_run.context.invoice == %{id: "inv_456", status: "open"}
      assert completed_run.context.delivery.invoice_id == "inv_456"
    end

    test "does not dispatch dependency join work after a sibling terminally fails the run" do
      :persistent_term.put({ConcurrentDependencyFailureWorkflow, :test_pid}, self())

      on_exit(fn ->
        :persistent_term.erase({ConcurrentDependencyFailureWorkflow, :test_pid})
      end)

      input = %{account_id: "acct_123", invoice_id: "inv_456"}

      assert {:ok, run} =
               SquidMesh.start_run(ConcurrentDependencyFailureWorkflow, input, repo: Repo)

      account_task =
        Task.async(fn ->
          StepWorker.perform(%Job{
            args: %{"run_id" => run.id, "step" => "load_account"}
          })
        end)

      invoice_task =
        Task.async(fn ->
          StepWorker.perform(%Job{
            args: %{"run_id" => run.id, "step" => "load_invoice"}
          })
        end)

      assert_receive {:concurrent_root_started, :load_account, account_pid}
      assert_receive {:concurrent_root_started, :load_invoice, invoice_pid}

      send(invoice_pid, :continue)

      assert :ok = Task.await(invoice_task)

      assert {:ok, failed_run} = SquidMesh.inspect_run(run.id, repo: Repo)
      assert failed_run.status == :failed
      assert failed_run.current_step == :load_invoice

      send(account_pid, :continue)

      assert :ok = Task.await(account_task)

      assert {:ok, persisted_run} = SquidMesh.inspect_run(run.id, repo: Repo)
      assert persisted_run.status == :failed
      assert persisted_run.current_step == :load_invoice
      refute Map.has_key?(persisted_run.context, :account)
      refute Map.has_key?(persisted_run.context, :delivery)

      assert 0 ==
               Repo.aggregate(
                 from(job in Job,
                   where:
                     job.worker == "SquidMesh.Workers.StepWorker" and
                       job.state == "available" and
                       fragment("?->>'run_id' = ?", job.args, ^run.id) and
                       fragment("?->>'step' = 'send_email'", job.args)
                 ),
                 :count
               )

      step_runs =
        Repo.all(
          from(step_run in StepRun,
            where: step_run.run_id == ^run.id,
            order_by: [asc: step_run.inserted_at]
          )
        )

      assert Enum.map(step_runs, &{&1.step, &1.status}) == [
               {"load_account", "completed"},
               {"load_invoice", "failed"}
             ]
    end

    test "keeps the run retrying when parallel dependency roots fail with retries" do
      :persistent_term.put({ConcurrentRetryWorkflow, :test_pid}, self())

      on_exit(fn ->
        :persistent_term.erase({ConcurrentRetryWorkflow, :test_pid})
      end)

      input = %{account_id: "acct_123", invoice_id: "inv_456"}

      assert {:ok, run} = SquidMesh.start_run(ConcurrentRetryWorkflow, input, repo: Repo)

      account_task =
        Task.async(fn ->
          StepWorker.perform(%Job{
            args: %{"run_id" => run.id, "step" => "load_account"}
          })
        end)

      invoice_task =
        Task.async(fn ->
          StepWorker.perform(%Job{
            args: %{"run_id" => run.id, "step" => "load_invoice"}
          })
        end)

      assert_receive {:concurrent_root_started, :load_account, account_pid}
      assert_receive {:concurrent_root_started, :load_invoice, invoice_pid}

      send(account_pid, :continue)
      send(invoice_pid, :continue)

      assert :ok = Task.await(account_task)
      assert :ok = Task.await(invoice_task)

      assert {:ok, retrying_run} = SquidMesh.inspect_run(run.id, repo: Repo)
      assert retrying_run.status == :retrying
      assert retrying_run.current_step in [:load_account, :load_invoice]
      assert retrying_run.last_error.code == "gateway_timeout"

      assert 4 ==
               Repo.aggregate(
                 from(job in Job,
                   where:
                     job.worker == "SquidMesh.Workers.StepWorker" and
                       job.state == "available" and
                       fragment("?->>'run_id' = ?", job.args, ^run.id) and
                       fragment("?->>'step' in ('load_account', 'load_invoice')", job.args)
                 ),
                 :count
               )

      step_runs =
        Repo.all(
          from(step_run in StepRun,
            where: step_run.run_id == ^run.id,
            order_by: [asc: step_run.inserted_at]
          )
        )

      assert Enum.sort(Enum.map(step_runs, &{&1.step, &1.status})) == [
               {"load_account", "failed"},
               {"load_invoice", "failed"}
             ]
    end

    test "persists failed step execution and marks the run failed when no retry is declared" do
      assert {:ok, run} =
               SquidMesh.start_run(FailingWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :squid_mesh)

      assert {:ok, failed_run} = SquidMesh.inspect_run(run.id, repo: Repo)

      assert failed_run.status == :failed
      assert failed_run.current_step == :check_gateway
      assert failed_run.last_error == %{message: "gateway timeout", code: "gateway_timeout"}

      assert %StepRun{} =
               step_run =
               Repo.one!(
                 from(step_run in StepRun,
                   where: step_run.run_id == ^run.id and step_run.step == "check_gateway"
                 )
               )

      assert step_run.status == "failed"
      assert step_run.last_error == %{"message" => "gateway timeout", "code" => "gateway_timeout"}
      assert AttemptStore.attempt_count(Repo, step_run.id) == 1
    end

    test "continues to the :error transition when a step fails without retry" do
      assert {:ok, run} =
               SquidMesh.start_run(ErrorRoutingWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert %{success: 2, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      assert {:ok, completed_run} =
               SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)

      assert completed_run.status == :completed
      assert completed_run.current_step == nil
      assert completed_run.last_error == nil
      assert completed_run.context == %{recovery: %{account_id: "acct_123", status: "queued"}}

      assert Enum.map(completed_run.step_runs, &{&1.step, &1.status}) == [
               {:check_gateway, :failed},
               {:queue_recovery, :completed}
             ]
    end

    test "continues to the :error transition only after retries are exhausted" do
      assert {:ok, run} =
               SquidMesh.start_run(ExhaustedRetryWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert %{success: 3, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      assert {:ok, completed_run} =
               SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)

      assert completed_run.status == :completed
      assert completed_run.current_step == nil
      assert completed_run.last_error == nil
      assert completed_run.context == %{recovery: %{account_id: "acct_123", status: "queued"}}

      assert [failed_step_run, recovery_step_run] = completed_run.step_runs
      assert {failed_step_run.step, failed_step_run.status} == {:check_gateway, :failed}
      assert {recovery_step_run.step, recovery_step_run.status} == {:queue_recovery, :completed}

      assert Enum.map(failed_step_run.attempts, &{&1.attempt_number, &1.status}) == [
               {1, :failed},
               {2, :failed}
             ]
    end

    test "executes built-in wait and log steps declaratively" do
      assert {:ok, run} =
               SquidMesh.start_run(BuiltInWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :squid_mesh)

      assert {:ok, waiting_run} = SquidMesh.inspect_run(run.id, repo: Repo)
      assert waiting_run.status == :running
      assert waiting_run.current_step == :log_delivery
      assert waiting_run.last_error == nil

      assert %Job{} =
               scheduled_job =
               Repo.one!(
                 from(job in Job,
                   where:
                     job.worker == "SquidMesh.Workers.StepWorker" and
                       job.state == "scheduled" and
                       fragment("?->>'run_id' = ?", job.args, ^run.id) and
                       fragment("?->>'step' = 'log_delivery'", job.args),
                   order_by: [desc: job.inserted_at],
                   limit: 1
                 )
               )

      assert DateTime.compare(scheduled_job.scheduled_at, scheduled_job.inserted_at) == :gt

      step_runs =
        Repo.all(
          from(step_run in StepRun,
            where: step_run.run_id == ^run.id,
            order_by: [asc: step_run.inserted_at]
          )
        )

      assert Enum.map(step_runs, &{&1.step, &1.status}) == [
               {"wait_for_settlement", "completed"}
             ]
    end

    test "schedules the next retry attempt through Oban when backoff is configured" do
      assert {:ok, run} =
               SquidMesh.start_run(BackoffWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :squid_mesh)

      assert {:ok, retried_run} = SquidMesh.inspect_run(run.id, repo: Repo)
      assert retried_run.status == :retrying
      assert retried_run.current_step == :check_gateway
      assert retried_run.last_error == %{message: "gateway timeout", code: "gateway_timeout"}

      assert %StepRun{} =
               step_run =
               Repo.one!(
                 from(step_run in StepRun,
                   where: step_run.run_id == ^run.id and step_run.step == "check_gateway"
                 )
               )

      assert AttemptStore.attempt_count(Repo, step_run.id) == 1

      assert %Job{} =
               scheduled_job =
               Repo.one!(
                 from(job in Job,
                   where:
                     job.worker == "SquidMesh.Workers.StepWorker" and
                       job.state == "scheduled" and
                       fragment("?->>'run_id' = ?", job.args, ^run.id),
                   order_by: [desc: job.inserted_at],
                   limit: 1
                 )
               )

      assert DateTime.compare(scheduled_job.scheduled_at, scheduled_job.inserted_at) == :gt
    end

    test "does not let Jido retries consume the workflow retry boundary" do
      :persistent_term.erase({RetrySurfaceWorkflow.FailOnce, :attempts})

      on_exit(fn ->
        :persistent_term.erase({RetrySurfaceWorkflow.FailOnce, :attempts})
      end)

      assert {:ok, run} =
               SquidMesh.start_run(RetrySurfaceWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :squid_mesh)

      assert {:ok, retried_run} = SquidMesh.inspect_run(run.id, repo: Repo)
      assert retried_run.status == :retrying
      assert retried_run.current_step == :check_gateway
      assert retried_run.last_error == %{message: "gateway timeout", code: "gateway_timeout"}

      assert %StepRun{} =
               step_run =
               Repo.one!(
                 from(step_run in StepRun,
                   where: step_run.run_id == ^run.id and step_run.step == "check_gateway"
                 )
               )

      assert step_run.status == "failed"
      assert AttemptStore.attempt_count(Repo, step_run.id) == 1
    end

    test "ignores stale step jobs after the run advances to the next step" do
      input = %{account_id: "acct_123", invoice_id: "inv_456"}

      assert {:ok, run} = SquidMesh.start_run(SuccessfulWorkflow, input, repo: Repo)

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "load_invoice"}
               })

      assert {:ok, running_run} = SquidMesh.inspect_run(run.id, repo: Repo)
      assert running_run.status == :running
      assert running_run.current_step == :send_email

      load_invoice_step_run =
        Repo.one!(
          from(step_run in StepRun,
            where: step_run.run_id == ^run.id and step_run.step == "load_invoice"
          )
        )

      assert AttemptStore.attempt_count(Repo, load_invoice_step_run.id) == 1

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "load_invoice"}
               })

      assert AttemptStore.attempt_count(Repo, load_invoice_step_run.id) == 1

      assert 1 ==
               Repo.aggregate(
                 from(job in Job,
                   where:
                     job.worker == "SquidMesh.Workers.StepWorker" and
                       job.state == "available" and
                       fragment("?->>'run_id' = ?", job.args, ^run.id) and
                       fragment("?->>'step' = 'send_email'", job.args)
                 ),
                 :count
               )
    end

    test "does not re-execute a step that is already marked running" do
      input = %{account_id: "acct_123", invoice_id: "inv_456"}

      assert {:ok, run} = SquidMesh.start_run(SuccessfulWorkflow, input, repo: Repo)
      assert {:ok, running_run} = SquidMesh.RunStore.transition_run(Repo, run.id, :running)

      assert {:ok, step_run, :execute} =
               StepRunStore.begin_step(Repo, running_run.id, :load_invoice, input)

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "load_invoice"}
               })

      assert AttemptStore.attempt_count(Repo, step_run.id) == 0

      assert %StepRun{status: "running"} =
               Repo.get!(StepRun, step_run.id)
    end

    test "marks the run failed when dispatching the next step fails after a successful step" do
      input = %{account_id: "acct_123", invoice_id: "inv_456"}

      assert {:ok, run} = SquidMesh.RunStore.create_run(Repo, SuccessfulWorkflow, input)
      assert :ok = StepExecutor.execute(run.id, nil, repo: Repo, execution: [name: MissingOban])

      assert {:ok, failed_run} = SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)

      assert failed_run.status == :failed
      assert failed_run.current_step == :send_email
      assert failed_run.context.account == %{id: "acct_123"}
      assert failed_run.context.invoice == %{id: "inv_456", status: "open"}
      assert failed_run.last_error.message == "failed to dispatch workflow step"
      assert failed_run.last_error.next_step == :send_email
      assert failed_run.last_error.cause.message =~ "No Oban instance named"

      assert [%SquidMesh.StepRun{} = step_run] = failed_run.step_runs
      assert step_run.step == :load_invoice
      assert step_run.status == :completed

      assert Enum.map(step_run.attempts, fn attempt ->
               {attempt.attempt_number, attempt.status}
             end) == [{1, :completed}]
    end

    test "preserves sibling dependency context when join dispatch fails after parallel success" do
      :persistent_term.put({ConcurrentDependencyWorkflow, :test_pid}, self())

      on_exit(fn ->
        :persistent_term.erase({ConcurrentDependencyWorkflow, :test_pid})
      end)

      input = %{account_id: "acct_123", invoice_id: "inv_456"}

      assert {:ok, run} = SquidMesh.start_run(ConcurrentDependencyWorkflow, input, repo: Repo)

      account_task =
        Task.async(fn ->
          StepExecutor.execute(run.id, :load_account, repo: Repo, execution: [name: MissingOban])
        end)

      invoice_task =
        Task.async(fn ->
          StepExecutor.execute(run.id, :load_invoice, repo: Repo, execution: [name: MissingOban])
        end)

      assert_receive {:concurrent_root_started, :load_account, account_pid}
      assert_receive {:concurrent_root_started, :load_invoice, invoice_pid}

      send(invoice_pid, :continue)

      assert :ok = Task.await(invoice_task)

      assert {:ok, invoice_run} = SquidMesh.inspect_run(run.id, repo: Repo)
      assert invoice_run.status == :running
      assert invoice_run.context.invoice == %{id: "inv_456", status: "open"}
      refute Map.has_key?(invoice_run.context, :account)

      send(account_pid, :continue)

      assert :ok = Task.await(account_task)

      assert {:ok, failed_run} = SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)

      assert failed_run.status == :failed
      assert failed_run.current_step == nil
      assert failed_run.context.account == %{id: "acct_123", tier: "pro"}
      assert failed_run.context.invoice == %{id: "inv_456", status: "open"}
      refute Map.has_key?(failed_run.context, :delivery)
      assert failed_run.last_error.message == "failed to dispatch workflow step"
      assert failed_run.last_error.next_steps == ["send_email"]
    end

    test "marks the run failed if dependency resolution cannot find a runnable next step" do
      config = Config.load!(repo: Repo)
      input = %{account_id: "acct_123", invoice_id: "inv_456"}

      assert {:ok, run} = SquidMesh.RunStore.create_run(Repo, DependencyWorkflow, input)

      assert {:ok, completed_root, :execute} =
               StepRunStore.begin_step(Repo, run.id, :load_account, input)

      assert {:ok, _completed_root} =
               StepRunStore.complete_step(Repo, completed_root.id, %{
                 account: %{id: "acct_123", tier: "pro"}
               })

      assert {:ok, prepared_run} =
               SquidMesh.RunStore.transition_run(Repo, run.id, :running, %{
                 current_step: :load_invoice,
                 context: %{account: %{id: "acct_123", tier: "pro"}}
               })

      assert {:ok, step_run, :execute} =
               StepRunStore.begin_step(Repo, prepared_run.id, :load_invoice, input)

      assert {:ok, attempt} = AttemptStore.begin_attempt(Repo, step_run.id)

      invalid_definition =
        DependencyWorkflow.workflow_definition()
        |> Map.update!(:steps, fn steps ->
          Enum.map(steps, fn
            %{name: :send_email} = step ->
              %{step | opts: [after: [:missing_dependency]]}

            step ->
              step
          end)
        end)

      assert :ok =
               Outcome.persist_execution_result(
                 {:ok, %{invoice: %{id: "inv_456", status: "open"}}, []},
                 :load_invoice,
                 config,
                 invalid_definition,
                 prepared_run,
                 step_run.id,
                 attempt.id,
                 attempt.attempt_number,
                 System.monotonic_time()
               )

      assert {:ok, failed_run} = SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)
      assert failed_run.status == :failed
      assert failed_run.current_step == :load_invoice
      assert failed_run.context.invoice == %{id: "inv_456", status: "open"}

      assert failed_run.last_error.message ==
               "workflow step completed but no runnable next step was found"

      assert failed_run.last_error.failed_step == :load_invoice
      assert failed_run.last_error.pending_steps == [:send_email]
    end

    test "marks the run failed if dependency resolution raises after the step succeeds" do
      config = Config.load!(repo: Repo)
      input = %{account_id: "acct_123", invoice_id: "inv_456"}

      assert {:ok, run} = SquidMesh.RunStore.create_run(Repo, DependencyWorkflow, input)

      assert {:ok, completed_root, :execute} =
               StepRunStore.begin_step(Repo, run.id, :load_account, input)

      assert {:ok, _completed_root} =
               StepRunStore.complete_step(Repo, completed_root.id, %{
                 account: %{id: "acct_123", tier: "pro"}
               })

      assert {:ok, prepared_run} =
               SquidMesh.RunStore.transition_run(Repo, run.id, :running, %{
                 current_step: :load_invoice,
                 context: %{account: %{id: "acct_123", tier: "pro"}}
               })

      assert {:ok, step_run, :execute} =
               StepRunStore.begin_step(Repo, prepared_run.id, :load_invoice, input)

      assert {:ok, attempt} = AttemptStore.begin_attempt(Repo, step_run.id)

      invalid_definition =
        DependencyWorkflow.workflow_definition()
        |> Map.update!(:steps, fn steps ->
          Enum.map(steps, fn
            %{name: :load_account} = step ->
              %{step | opts: [after: [:send_email]]}

            %{name: :send_email} = step ->
              %{step | opts: [after: [:load_account, :load_invoice]]}

            step ->
              step
          end)
        end)

      assert :ok =
               Outcome.persist_execution_result(
                 {:ok, %{invoice: %{id: "inv_456", status: "open"}}, []},
                 :load_invoice,
                 config,
                 invalid_definition,
                 prepared_run,
                 step_run.id,
                 attempt.id,
                 attempt.attempt_number,
                 System.monotonic_time()
               )

      assert {:ok, failed_run} = SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)
      assert failed_run.status == :failed
      assert failed_run.current_step == :load_invoice
      assert failed_run.context.invoice == %{id: "inv_456", status: "open"}

      assert failed_run.last_error.message ==
               "workflow step completed but next step resolution failed"

      assert failed_run.last_error.failed_step == :load_invoice

      assert failed_run.last_error.cause == %{
               reason: "invalid_dependency_graph",
               message: "workflow dependency graph must be acyclic"
             }
    end

    test "marks the run failed when scheduling a retry fails" do
      assert {:ok, run} =
               SquidMesh.RunStore.create_run(Repo, BackoffWorkflow, %{account_id: "acct_123"})

      assert :ok = StepExecutor.execute(run.id, nil, repo: Repo, execution: [name: MissingOban])

      assert {:ok, failed_run} = SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)

      assert failed_run.status == :failed
      assert failed_run.current_step == :check_gateway
      assert failed_run.last_error.message == "failed to dispatch workflow step"
      assert failed_run.last_error.failed_step == :check_gateway
      assert failed_run.last_error.cause == %{message: "gateway timeout", code: "gateway_timeout"}

      assert [%SquidMesh.StepRun{} = step_run] = failed_run.step_runs
      assert step_run.step == :check_gateway
      assert step_run.status == :failed

      assert Enum.map(step_run.attempts, fn attempt ->
               {attempt.attempt_number, attempt.status}
             end) == [{1, :failed}]
    end

    test "converges cancelling runs to cancelled even when a stale scheduled step arrives" do
      assert {:ok, run} =
               SquidMesh.start_run(BuiltInWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :squid_mesh)

      assert {:ok, cancelling_run} = SquidMesh.cancel_run(run.id, repo: Repo)
      assert cancelling_run.status == :cancelling
      assert cancelling_run.current_step == nil

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "log_delivery"}
               })

      assert {:ok, cancelled_run} = SquidMesh.inspect_run(run.id, repo: Repo)
      assert cancelled_run.status == :cancelled
      assert cancelled_run.current_step == nil
    end

    test "converges to cancelled when a post-wait step finishes after cancellation is requested" do
      :persistent_term.put({CancellationCompletionWorkflow.RecordDelivery, :test_pid}, self())

      on_exit(fn ->
        :persistent_term.erase({CancellationCompletionWorkflow.RecordDelivery, :test_pid})
      end)

      assert {:ok, run} =
               SquidMesh.start_run(
                 CancellationCompletionWorkflow,
                 %{account_id: "acct_123"},
                 repo: Repo
               )

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :squid_mesh)

      assert {:ok, ready_run} = SquidMesh.inspect_run(run.id, repo: Repo)
      assert ready_run.status == :running
      assert ready_run.current_step == :record_delivery

      task =
        Task.async(fn ->
          StepWorker.perform(%Job{
            args: %{"run_id" => run.id, "step" => "record_delivery"}
          })
        end)

      assert_receive {:record_delivery_started, delivery_pid, "acct_123"}

      assert {:ok, cancelling_run} = SquidMesh.cancel_run(run.id, repo: Repo)
      assert cancelling_run.status == :cancelling

      send(delivery_pid, :continue)

      assert :ok = Task.await(task)

      assert {:ok, cancelled_run} = SquidMesh.inspect_run(run.id, repo: Repo)
      assert cancelled_run.status == :cancelled
      assert cancelled_run.current_step == nil
    end

    test "finalizes pause step history when cancellation wins before pause progression" do
      assert {:ok, config} = Config.load(repo: Repo)
      assert {:ok, definition} = SquidMesh.Workflow.Definition.load(PauseWorkflow)

      assert {:ok, run} =
               SquidMesh.start_run(
                 PauseWorkflow,
                 %{account_id: "acct_123"},
                 repo: Repo
               )

      assert {:ok, running_run} =
               SquidMesh.RunStore.transition_run(Repo, run.id, :running, %{
                 current_step: :wait_for_approval
               })

      assert {:ok, step_run, :execute} =
               StepRunStore.begin_step(Repo, run.id, :wait_for_approval, %{
                 account_id: "acct_123"
               })

      assert {:ok, attempt} = AttemptStore.begin_attempt(Repo, step_run.id)

      assert {:ok, cancelling_run} = SquidMesh.cancel_run(run.id, repo: Repo)
      assert cancelling_run.status == :cancelling

      started_at = System.monotonic_time()

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
                 started_at
               )

      assert {:ok, cancelled_run} =
               SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)

      assert cancelled_run.status == :cancelled
      assert cancelled_run.current_step == nil

      assert [%SquidMesh.StepRun{} = paused_step] = cancelled_run.step_runs
      assert paused_step.step == :wait_for_approval
      assert paused_step.status == :failed
      assert paused_step.output == nil

      assert paused_step.last_error == %{
               message: "run cancelled while paused",
               reason: "cancelled"
             }

      assert Enum.map(paused_step.attempts, &{&1.status, &1.error}) == [
               {:failed, %{message: "run cancelled while paused", reason: "cancelled"}}
             ]
    end
  end

  defmodule DependencyWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
          field(:invoice_id, :string)
        end
      end

      step(:load_account, DependencyWorkflow.LoadAccount)
      step(:load_invoice, DependencyWorkflow.LoadInvoice)
      step(:send_email, DependencyWorkflow.SendEmail, after: [:load_account, :load_invoice])
    end
  end

  defmodule DependencyFailureWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
          field(:invoice_id, :string)
        end
      end

      step(:load_account, DependencyWorkflow.LoadAccount)
      step(:load_invoice, DependencyFailureWorkflow.LoadInvoice)
      step(:send_email, DependencyWorkflow.SendEmail, after: [:load_account, :load_invoice])
    end
  end

  defmodule DependencyWorkflow.LoadAccount do
    use Jido.Action,
      name: "load_account",
      description: "Loads account details",
      schema: [
        account_id: [type: :string, required: true]
      ]

    @impl true
    def run(%{account_id: account_id}, _context) do
      {:ok, %{account: %{id: account_id, tier: "pro"}}}
    end
  end

  defmodule DependencyWorkflow.LoadInvoice do
    use Jido.Action,
      name: "load_invoice",
      description: "Loads invoice details",
      schema: [
        invoice_id: [type: :string, required: true]
      ]

    @impl true
    def run(%{invoice_id: invoice_id}, _context) do
      {:ok, %{invoice: %{id: invoice_id, status: "open"}}}
    end
  end

  defmodule DependencyWorkflow.SendEmail do
    use Jido.Action,
      name: "send_email",
      description: "Sends a recovery email after both inputs are ready",
      schema: [
        account: [type: :map, required: true],
        invoice: [type: :map, required: true]
      ]

    @impl true
    def run(%{account: account, invoice: invoice}, _context) do
      {:ok,
       %{
         delivery: %{
           account_id: account.id,
           invoice_id: invoice.id,
           channel: "email"
         }
       }}
    end
  end

  defmodule OrderedDependencyWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
          field(:invoice_id, :string)
        end
      end

      step(:load_account, DependencyWorkflow.LoadAccount)

      step(:prepare_account_message, OrderedDependencyWorkflow.PrepareAccountMessage,
        after: [:load_account]
      )

      step(:load_invoice, DependencyWorkflow.LoadInvoice)

      step(:send_email, OrderedDependencyWorkflow.SendEmail,
        after: [:prepare_account_message, :load_invoice]
      )
    end
  end

  defmodule OrderedDependencyWorkflow.PrepareAccountMessage do
    use Jido.Action,
      name: "prepare_account_message",
      description: "Builds intermediate account context",
      schema: [
        account: [type: :map, required: true]
      ]

    @impl true
    def run(%{account: account}, _context) do
      {:ok, %{account_message: %{account_id: account.id, status: "prepared"}}}
    end
  end

  defmodule OrderedDependencyWorkflow.SendEmail do
    use Jido.Action,
      name: "send_email",
      description: "Sends a recovery email after ordered dependency execution",
      schema: [
        account_message: [type: :map, required: true],
        invoice: [type: :map, required: true]
      ]

    @impl true
    def run(%{account_message: account_message, invoice: invoice}, _context) do
      {:ok,
       %{
         delivery: %{
           account_id: account_message.account_id,
           invoice_id: invoice.id,
           channel: "email"
         }
       }}
    end
  end

  defmodule InputIsolationWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
          field(:invoice_id, :string)
        end
      end

      step(:load_account, DependencyWorkflow.LoadAccount)
      step(:load_invoice, InputIsolationWorkflow.LoadInvoice)

      step(:complete_run, :log,
        message: "dependency roots completed",
        after: [:load_account, :load_invoice]
      )
    end
  end

  defmodule InputIsolationWorkflow.LoadInvoice do
    use Jido.Action,
      name: "load_invoice",
      description: "Checks whether sibling context leaked into a scheduled root step",
      schema: [
        invoice_id: [type: :string, required: true]
      ]

    @impl true
    def run(%{invoice_id: invoice_id} = input, _context) do
      {:ok,
       %{
         invoice: %{
           id: invoice_id,
           account_present?: Map.has_key?(input, :account)
         }
       }}
    end
  end

  defmodule ConcurrentDependencyWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
          field(:invoice_id, :string)
        end
      end

      step(:load_account, ConcurrentDependencyWorkflow.LoadAccount)
      step(:load_invoice, ConcurrentDependencyWorkflow.LoadInvoice)
      step(:send_email, DependencyWorkflow.SendEmail, after: [:load_account, :load_invoice])
    end
  end

  defmodule ConcurrentDependencyWorkflow.LoadAccount do
    use Jido.Action,
      name: "load_account",
      description: "Blocks until the test releases the account root",
      schema: [
        account_id: [type: :string, required: true]
      ]

    @impl true
    def run(%{account_id: account_id}, _context) do
      notify_test(:load_account)
      await_continue()
      {:ok, %{account: %{id: account_id, tier: "pro"}}}
    end

    defp notify_test(step_name) do
      case :persistent_term.get({ConcurrentDependencyWorkflow, :test_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:concurrent_root_started, step_name, self()})
        _other -> :ok
      end
    end

    defp await_continue do
      receive do
        :continue -> :ok
      after
        1_000 -> raise "timed out waiting for concurrent root release"
      end
    end
  end

  defmodule ConcurrentDependencyWorkflow.LoadInvoice do
    use Jido.Action,
      name: "load_invoice",
      description: "Blocks until the test releases the invoice root",
      schema: [
        invoice_id: [type: :string, required: true]
      ]

    @impl true
    def run(%{invoice_id: invoice_id}, _context) do
      notify_test(:load_invoice)
      await_continue()
      {:ok, %{invoice: %{id: invoice_id, status: "open"}}}
    end

    defp notify_test(step_name) do
      case :persistent_term.get({ConcurrentDependencyWorkflow, :test_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:concurrent_root_started, step_name, self()})
        _other -> :ok
      end
    end

    defp await_continue do
      receive do
        :continue -> :ok
      after
        1_000 -> raise "timed out waiting for concurrent root release"
      end
    end
  end

  defmodule ConcurrentDependencyFailureWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
          field(:invoice_id, :string)
        end
      end

      step(:load_account, ConcurrentDependencyFailureWorkflow.LoadAccount)
      step(:load_invoice, ConcurrentDependencyFailureWorkflow.LoadInvoice)
      step(:send_email, DependencyWorkflow.SendEmail, after: [:load_account, :load_invoice])
    end
  end

  defmodule ConcurrentDependencyFailureWorkflow.LoadAccount do
    use Jido.Action,
      name: "load_account",
      description: "Completes after the test releases the successful root",
      schema: [
        account_id: [type: :string, required: true]
      ]

    @impl true
    def run(%{account_id: account_id}, _context) do
      notify_test(:load_account)
      await_continue()
      {:ok, %{account: %{id: account_id, tier: "pro"}}}
    end

    defp notify_test(step_name) do
      case :persistent_term.get({ConcurrentDependencyFailureWorkflow, :test_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:concurrent_root_started, step_name, self()})
        _other -> :ok
      end
    end

    defp await_continue do
      receive do
        :continue -> :ok
      after
        1_000 -> raise "timed out waiting for concurrent root release"
      end
    end
  end

  defmodule ConcurrentDependencyFailureWorkflow.LoadInvoice do
    use Jido.Action,
      name: "load_invoice",
      description: "Fails after the test releases the failing root",
      schema: [
        invoice_id: [type: :string, required: true]
      ]

    @impl true
    def run(%{invoice_id: invoice_id}, _context) do
      notify_test(:load_invoice)
      await_continue()

      {:error,
       %{message: "invoice unavailable", code: "invoice_unavailable", invoice_id: invoice_id}}
    end

    defp notify_test(step_name) do
      case :persistent_term.get({ConcurrentDependencyFailureWorkflow, :test_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:concurrent_root_started, step_name, self()})
        _other -> :ok
      end
    end

    defp await_continue do
      receive do
        :continue -> :ok
      after
        1_000 -> raise "timed out waiting for concurrent root release"
      end
    end
  end

  defmodule ConcurrentRetryWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
          field(:invoice_id, :string)
        end
      end

      step(:load_account, ConcurrentRetryWorkflow.LoadAccount, retry: [max_attempts: 2])
      step(:load_invoice, ConcurrentRetryWorkflow.LoadInvoice, retry: [max_attempts: 2])
      step(:send_email, DependencyWorkflow.SendEmail, after: [:load_account, :load_invoice])
    end
  end

  defmodule ConcurrentRetryWorkflow.LoadAccount do
    use Jido.Action,
      name: "load_account",
      description: "Fails after the test releases the retryable account root",
      schema: [
        account_id: [type: :string, required: true]
      ]

    @impl true
    def run(%{account_id: account_id}, _context) do
      notify_test(:load_account)
      await_continue()

      {:error, %{message: "gateway timeout", code: "gateway_timeout", account_id: account_id}}
    end

    defp notify_test(step_name) do
      case :persistent_term.get({ConcurrentRetryWorkflow, :test_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:concurrent_root_started, step_name, self()})
        _other -> :ok
      end
    end

    defp await_continue do
      receive do
        :continue -> :ok
      after
        1_000 -> raise "timed out waiting for concurrent root release"
      end
    end
  end

  defmodule ConcurrentRetryWorkflow.LoadInvoice do
    use Jido.Action,
      name: "load_invoice",
      description: "Fails after the test releases the retryable invoice root",
      schema: [
        invoice_id: [type: :string, required: true]
      ]

    @impl true
    def run(%{invoice_id: invoice_id}, _context) do
      notify_test(:load_invoice)
      await_continue()

      {:error, %{message: "gateway timeout", code: "gateway_timeout", invoice_id: invoice_id}}
    end

    defp notify_test(step_name) do
      case :persistent_term.get({ConcurrentRetryWorkflow, :test_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:concurrent_root_started, step_name, self()})
        _other -> :ok
      end
    end

    defp await_continue do
      receive do
        :continue -> :ok
      after
        1_000 -> raise "timed out waiting for concurrent root release"
      end
    end
  end

  defmodule DependencyFailureWorkflow.LoadInvoice do
    use Jido.Action,
      name: "load_invoice",
      description: "Fails while loading invoice details",
      schema: [
        invoice_id: [type: :string, required: true]
      ]

    @impl true
    def run(%{invoice_id: invoice_id}, _context) do
      {:error,
       %{message: "invoice unavailable", code: "invoice_unavailable", invoice_id: invoice_id}}
    end
  end

  defmodule SuccessfulWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
          field(:invoice_id, :string)
        end
      end

      step(:load_invoice, SuccessfulWorkflow.LoadInvoice)
      step(:send_email, SuccessfulWorkflow.SendEmail)

      transition(:load_invoice, on: :ok, to: :send_email)
      transition(:send_email, on: :ok, to: :complete)
    end
  end

  defmodule ExplicitMappingWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
          field(:invoice_id, :string)
        end
      end

      step(:load_account, ExplicitMappingWorkflow.LoadAccount,
        input: [:account_id],
        output: :account
      )

      step(:record_delivery, ExplicitMappingWorkflow.RecordDelivery,
        input: [:account, :invoice_id],
        output: :delivery
      )

      transition(:load_account, on: :ok, to: :record_delivery)
      transition(:record_delivery, on: :ok, to: :complete)
    end
  end

  defmodule ExplicitMappingWorkflow.LoadAccount do
    use Jido.Action,
      name: "load_account",
      description: "Loads one account from an explicit input mapping",
      schema: [
        account_id: [type: :string, required: true]
      ]

    @impl true
    def run(%{account_id: account_id}, _context) do
      {:ok, %{id: account_id}}
    end
  end

  defmodule ExplicitMappingWorkflow.RecordDelivery do
    use Jido.Action,
      name: "record_delivery",
      description: "Builds delivery output from explicitly mapped inputs",
      schema: [
        account: [type: :map, required: true],
        invoice_id: [type: :string, required: true]
      ]

    @impl true
    def run(%{account: account, invoice_id: invoice_id}, _context) do
      {:ok, %{account_id: account.id, invoice_id: invoice_id}}
    end
  end

  defmodule SuccessfulWorkflow.LoadInvoice do
    use Jido.Action,
      name: "load_invoice",
      description: "Loads invoice details",
      schema: [
        account_id: [type: :string, required: true],
        invoice_id: [type: :string, required: true]
      ]

    @impl true
    def run(%{account_id: account_id, invoice_id: invoice_id}, _context) do
      {:ok,
       %{
         account: %{id: account_id},
         invoice: %{id: invoice_id, status: "open"}
       }}
    end
  end

  defmodule SuccessfulWorkflow.SendEmail do
    use Jido.Action,
      name: "send_email",
      description: "Sends a recovery email",
      schema: [
        account: [type: :map, required: true],
        invoice: [type: :map, required: true]
      ]

    @impl true
    def run(%{account: account, invoice: invoice}, _context) do
      {:ok,
       %{
         delivery: %{
           account_id: account.id,
           invoice_id: invoice.id,
           channel: "email"
         }
       }}
    end
  end

  defmodule FailingWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
        end
      end

      step(:check_gateway, FailingWorkflow.CheckGateway)
      transition(:check_gateway, on: :ok, to: :complete)
    end
  end

  defmodule FailingWorkflow.CheckGateway do
    use Jido.Action,
      name: "check_gateway",
      description: "Checks gateway availability",
      schema: [
        account_id: [type: :string, required: true]
      ]

    @impl true
    def run(_params, _context) do
      {:error, %{message: "gateway timeout", code: "gateway_timeout"}}
    end
  end

  defmodule BackoffWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
        end
      end

      step(:check_gateway, BackoffWorkflow.CheckGateway,
        retry: [max_attempts: 3, backoff: [type: :exponential, min: 1_000, max: 5_000]]
      )

      transition(:check_gateway, on: :ok, to: :complete)
    end
  end

  defmodule BackoffWorkflow.CheckGateway do
    use Jido.Action,
      name: "check_gateway",
      description: "Checks gateway availability with retry backoff",
      schema: [
        account_id: [type: :string, required: true]
      ]

    @impl true
    def run(_params, _context) do
      {:error, %{message: "gateway timeout", code: "gateway_timeout"}}
    end
  end

  defmodule ErrorRoutingWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
        end
      end

      step(:check_gateway, ErrorRoutingWorkflow.CheckGateway)
      step(:queue_recovery, ErrorRoutingWorkflow.QueueRecovery)

      transition(:check_gateway, on: :error, to: :queue_recovery)
      transition(:queue_recovery, on: :ok, to: :complete)
    end
  end

  defmodule ErrorRoutingWorkflow.CheckGateway do
    use Jido.Action,
      name: "check_gateway",
      description: "Fails and routes to recovery",
      schema: [
        account_id: [type: :string, required: true]
      ]

    @impl true
    def run(_params, _context) do
      {:error, %{message: "gateway timeout", code: "gateway_timeout"}}
    end
  end

  defmodule ErrorRoutingWorkflow.QueueRecovery do
    use Jido.Action,
      name: "queue_recovery",
      description: "Queues a recovery action after failure routing",
      schema: [
        account_id: [type: :string, required: true]
      ]

    @impl true
    def run(%{account_id: account_id}, _context) do
      {:ok, %{recovery: %{account_id: account_id, status: "queued"}}}
    end
  end

  defmodule ExhaustedRetryWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
        end
      end

      step(:check_gateway, ExhaustedRetryWorkflow.CheckGateway, retry: [max_attempts: 2])
      step(:queue_recovery, ExhaustedRetryWorkflow.QueueRecovery)

      transition(:check_gateway, on: :error, to: :queue_recovery)
      transition(:queue_recovery, on: :ok, to: :complete)
    end
  end

  defmodule ExhaustedRetryWorkflow.CheckGateway do
    use Jido.Action,
      name: "check_gateway",
      description: "Fails until retries are exhausted and error routing can continue",
      schema: [
        account_id: [type: :string, required: true]
      ]

    @impl true
    def run(_params, _context) do
      {:error, %{message: "gateway timeout", code: "gateway_timeout"}}
    end
  end

  defmodule ExhaustedRetryWorkflow.QueueRecovery do
    use Jido.Action,
      name: "queue_recovery",
      description: "Queues recovery after retries are exhausted",
      schema: [
        account_id: [type: :string, required: true]
      ]

    @impl true
    def run(%{account_id: account_id}, _context) do
      {:ok, %{recovery: %{account_id: account_id, status: "queued"}}}
    end
  end

  defmodule RetrySurfaceWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
        end
      end

      step(:check_gateway, RetrySurfaceWorkflow.FailOnce,
        retry: [max_attempts: 3, backoff: [type: :exponential, min: 1_000, max: 5_000]]
      )

      transition(:check_gateway, on: :ok, to: :complete)
    end
  end

  defmodule RetrySurfaceWorkflow.FailOnce do
    use Jido.Action,
      name: "check_gateway",
      description: "Fails once so Squid Mesh owns the retry boundary",
      schema: [
        account_id: [type: :string, required: true]
      ]

    @coordination_key {__MODULE__, :attempts}

    @impl true
    def run(%{account_id: account_id}, %{run_id: run_id}) do
      seen_runs = :persistent_term.get(@coordination_key, MapSet.new())

      if MapSet.member?(seen_runs, run_id) do
        {:ok, %{gateway_check: %{account_id: account_id, status: "ok"}}}
      else
        :persistent_term.put(@coordination_key, MapSet.put(seen_runs, run_id))
        {:error, %{message: "gateway timeout", code: "gateway_timeout"}}
      end
    end
  end

  defmodule BuiltInWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
        end
      end

      step(:wait_for_settlement, :wait, duration: 10)
      step(:log_delivery, :log, message: "delivery completed", level: :info)

      transition(:wait_for_settlement, on: :ok, to: :log_delivery)
      transition(:log_delivery, on: :ok, to: :complete)
    end
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

  defmodule PauseMappedWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
        end
      end

      step(:wait_for_approval, :pause, output: :approval)

      step(:record_delivery, PauseMappedWorkflow.RecordDelivery,
        input: [:approval, :account_id],
        output: :delivery
      )

      transition(:wait_for_approval, on: :ok, to: :record_delivery)
      transition(:record_delivery, on: :ok, to: :complete)
    end
  end

  defmodule PauseMappedWorkflow.RecordDelivery do
    use Jido.Action,
      name: "record_delivery",
      description: "Confirms pause output mappings flow into the resumed step",
      schema: [
        approval: [type: :map, required: true],
        account_id: [type: :string, required: true]
      ]

    @impl true
    def run(%{approval: approval, account_id: account_id}, _context) do
      {:ok, %{account_id: account_id, approval: approval}}
    end
  end

  defmodule CancellationCompletionWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
        end
      end

      step(:wait_for_settlement, :wait, duration: 10)
      step(:record_delivery, CancellationCompletionWorkflow.RecordDelivery)

      transition(:wait_for_settlement, on: :ok, to: :record_delivery)
      transition(:record_delivery, on: :ok, to: :complete)
    end
  end

  defmodule CancellationCompletionWorkflow.RecordDelivery do
    use Jido.Action,
      name: "record_delivery",
      description: "Blocks until the test allows completion",
      schema: [
        account_id: [type: :string, required: true]
      ]

    @coordination_key {__MODULE__, :test_pid}

    @impl true
    def run(%{account_id: account_id}, _context) do
      test_pid = :persistent_term.get(@coordination_key)
      send(test_pid, {:record_delivery_started, self(), account_id})

      receive do
        :continue -> {:ok, %{delivery: %{account_id: account_id, status: "recorded"}}}
      after
        5_000 -> {:error, %{message: "timed out waiting for test continuation"}}
      end
    end
  end

  defmodule MissingOban do
  end
end
