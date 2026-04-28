defmodule SquidMesh.Runtime.StepWorkerTest do
  use SquidMesh.DataCase

  import Ecto.Query

  alias SquidMesh.AttemptStore
  alias SquidMesh.Persistence.StepRun
  alias Oban.Job

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

  describe "workflow execution through Oban" do
    test "enqueues and executes the declared steps through Jido-backed actions" do
      input = %{account_id: "acct_123", invoice_id: "inv_456"}

      assert {:ok, run} = SquidMesh.start_run(SuccessfulWorkflow, input, repo: Repo)

      assert_enqueued(
        worker: SquidMesh.Workers.StepWorker,
        queue: "squid_mesh",
        args: %{"run_id" => run.id}
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

    test "executes built-in wait and log steps declaratively" do
      assert {:ok, run} =
               SquidMesh.start_run(BuiltInWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert %{success: 2, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      assert {:ok, completed_run} = SquidMesh.inspect_run(run.id, repo: Repo)
      assert completed_run.status == :completed
      assert completed_run.current_step == nil
      assert completed_run.last_error == nil

      step_runs =
        Repo.all(
          from(step_run in StepRun,
            where: step_run.run_id == ^run.id,
            order_by: [asc: step_run.inserted_at]
          )
        )

      assert Enum.map(step_runs, &{&1.step, &1.status}) == [
               {"wait_for_settlement", "completed"},
               {"log_delivery", "completed"}
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
  end
end
