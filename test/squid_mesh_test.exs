defmodule SquidMeshTest do
  use SquidMesh.DataCase

  alias SquidMesh.Persistence.Run, as: RunRecord
  alias SquidMesh.Persistence.Run, as: PersistedRun
  alias SquidMesh.Run
  alias SquidMesh.RunStore
  alias SquidMesh.StepAttempt, as: PublicStepAttempt
  alias SquidMesh.StepRun, as: PublicStepRun
  alias SquidMesh.TestSupport.LazyWorkflow
  alias SquidMesh.Workers.CronTriggerWorker

  defmodule InvoiceReminderWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :invoice_delivery do
        manual()

        payload do
          field(:account_id, :string)
          field(:invoice_id, :string)
        end
      end

      step(:load_invoice, InvoiceReminderWorkflow.LoadInvoice)
      step(:send_email, InvoiceReminderWorkflow.SendEmail, retry: [max_attempts: 3])

      transition(:load_invoice, on: :ok, to: :send_email)
      transition(:send_email, on: :ok, to: :complete)
    end
  end

  defmodule PaymentRecoveryWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :gateway_recovery do
        manual()

        payload do
          field(:account_id, :string)
        end
      end

      step(:check_gateway, PaymentRecoveryWorkflow.CheckGateway, retry: [max_attempts: 2])
      transition(:check_gateway, on: :ok, to: :complete)
    end
  end

  defmodule ReorderedWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :invoice_delivery do
        manual()

        payload do
          field(:account_id, :string)
        end
      end

      step(:send_email, ReorderedWorkflow.SendEmail)
      step(:load_invoice, ReorderedWorkflow.LoadInvoice)

      transition(:load_invoice, on: :ok, to: :send_email)
      transition(:send_email, on: :ok, to: :complete)
    end
  end

  defmodule InvoiceReminderWorkflow.LoadInvoice do
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

  defmodule InvoiceReminderWorkflow.SendEmail do
    use Jido.Action,
      name: "send_email",
      description: "Sends an invoice reminder email",
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

  defmodule PaymentRecoveryWorkflow.CheckGateway do
    use Jido.Action,
      name: "check_gateway",
      description: "Checks payment gateway status",
      schema: [
        account_id: [type: :string, required: true]
      ]

    @impl true
    def run(%{account_id: account_id}, _context) do
      {:ok, %{gateway_check: %{account_id: account_id, status: "healthy"}}}
    end
  end

  defmodule ReorderedWorkflow.LoadInvoice do
    defdelegate run(params, context), to: InvoiceReminderWorkflow.LoadInvoice
  end

  defmodule ReorderedWorkflow.SendEmail do
    defdelegate run(params, context), to: InvoiceReminderWorkflow.SendEmail
  end

  defmodule WorkflowWithPayloadDefaults do
    use SquidMesh.Workflow

    workflow do
      trigger :invoice_delivery do
        manual()

        payload do
          field(:team_id, :string, default: "backend")
          field(:prompt_date, :string, default: {:today, :iso8601})
          field(:invoice_id, :string)
        end
      end

      step(:deliver_invoice, WorkflowWithPayloadDefaults.DeliverInvoice)
      transition(:deliver_invoice, on: :ok, to: :complete)
    end
  end

  defmodule DailyStandupWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :daily_standup do
        cron("@reboot", timezone: "Etc/UTC")

        payload do
          field(:team_id, :string, default: "backend")
          field(:prompt_date, :string, default: {:today, :iso8601})
        end
      end

      step(:announce_prompt, :log, message: "posting daily standup")
      transition(:announce_prompt, on: :ok, to: :complete)
    end
  end

  defmodule MissingOban do
  end

  test "configures an application supervisor" do
    assert Application.spec(:squid_mesh, :mod) == {SquidMesh.Application, []}
  end

  test "loads the public entrypoint module" do
    assert Code.ensure_loaded?(SquidMesh)
  end

  describe "config/1" do
    test "returns the validated host app contract with defaults" do
      assert {:ok, config} = SquidMesh.config(repo: SquidMeshTest.Repo)

      assert config.repo == SquidMeshTest.Repo
      assert config.execution_name == Oban
      assert config.execution_queue == :squid_mesh
    end

    test "allows host applications to override execution settings" do
      overrides = [repo: SquidMeshTest.Repo, execution: [name: MyApp.Oban, queue: :workflows]]

      assert {:ok, config} = SquidMesh.config(overrides)

      assert config.execution_name == MyApp.Oban
      assert config.execution_queue == :workflows
    end

    test "reports missing required configuration keys" do
      original_repo = Application.get_env(:squid_mesh, :repo)

      on_exit(fn ->
        Application.put_env(:squid_mesh, :repo, original_repo)
      end)

      Application.delete_env(:squid_mesh, :repo)

      assert {:error, {:missing_config, [:repo]}} = SquidMesh.config()
    end
  end

  describe "start_run/3" do
    test "persists a new run and returns the public run shape" do
      payload = %{account_id: "acct_123", invoice_id: "inv_456"}

      assert {:ok, %Run{} = run} =
               SquidMesh.start_run(InvoiceReminderWorkflow, payload, repo: Repo)

      assert run.workflow == InvoiceReminderWorkflow
      assert run.trigger == :invoice_delivery
      assert run.status == :pending
      assert run.payload == payload
      assert run.context == %{}
      assert run.current_step == :load_invoice
      assert run.last_error == nil
      assert is_binary(run.id)
      assert %DateTime{} = run.inserted_at
      assert %DateTime{} = run.updated_at
    end

    test "rejects modules that do not define the workflow contract" do
      assert {:error, {:invalid_workflow, String}} =
               SquidMesh.start_run(String, %{}, repo: Repo)
    end

    test "loads workflow modules on demand before validating the contract" do
      :code.purge(LazyWorkflow)
      :code.delete(LazyWorkflow)

      refute :code.is_loaded(LazyWorkflow)

      assert {:ok, %Run{} = run} =
               SquidMesh.start_run(LazyWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert run.workflow == LazyWorkflow
    end

    test "starts a run through an explicit trigger name" do
      assert {:ok, %Run{} = run} =
               SquidMesh.start_run(
                 InvoiceReminderWorkflow,
                 :invoice_delivery,
                 %{account_id: "acct_123", invoice_id: "inv_456"},
                 repo: Repo
               )

      assert run.trigger == :invoice_delivery
    end

    test "rejects unknown trigger names" do
      assert {:error, {:invalid_trigger, :unknown_trigger}} =
               SquidMesh.start_run(
                 InvoiceReminderWorkflow,
                 :unknown_trigger,
                 %{account_id: "acct_123", invoice_id: "inv_456"},
                 repo: Repo
               )
    end

    test "rejects non-map payloads" do
      assert {:error, {:invalid_payload, :expected_map}} =
               SquidMesh.start_run(InvoiceReminderWorkflow, [:not_a_map], repo: Repo)
    end

    test "starts from the semantic entry step rather than declaration order" do
      assert {:ok, run} =
               SquidMesh.start_run(ReorderedWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert run.current_step == :load_invoice
    end

    test "rejects payloads with missing required fields" do
      assert {:error, {:invalid_payload, %{missing_fields: [:invoice_id]}}} =
               SquidMesh.start_run(InvoiceReminderWorkflow, %{account_id: "acct_123"}, repo: Repo)
    end

    test "rejects payloads with undeclared fields" do
      assert {:error, {:invalid_payload, %{unknown_fields: [:unexpected]}}} =
               SquidMesh.start_run(
                 InvoiceReminderWorkflow,
                 %{account_id: "acct_123", invoice_id: "inv_456", unexpected: true},
                 repo: Repo
               )
    end

    test "rejects payload fields with invalid types" do
      assert {:error, {:invalid_payload, %{invalid_types: %{invoice_id: :string}}}} =
               SquidMesh.start_run(
                 InvoiceReminderWorkflow,
                 %{account_id: "acct_123", invoice_id: 123},
                 repo: Repo
               )
    end

    test "applies payload defaults before persistence" do
      assert {:ok, %Run{} = run} =
               SquidMesh.start_run(
                 WorkflowWithPayloadDefaults,
                 %{invoice_id: "inv_456"},
                 repo: Repo
               )

      assert run.payload == %{
               team_id: "backend",
               prompt_date: Date.utc_today() |> Date.to_iso8601(),
               invoice_id: "inv_456"
             }
    end

    test "allows provided payload values to override defaults" do
      assert {:ok, %Run{} = run} =
               SquidMesh.start_run(
                 WorkflowWithPayloadDefaults,
                 %{
                   invoice_id: "inv_456",
                   team_id: "payments",
                   prompt_date: "2026-01-15"
                 },
                 repo: Repo
               )

      assert run.payload == %{
               team_id: "payments",
               prompt_date: "2026-01-15",
               invoice_id: "inv_456"
             }
    end

    test "rolls back run creation when dispatching the first step fails" do
      before_count = Repo.aggregate(RunRecord, :count, :id)

      assert {:error, {:dispatch_failed, %RuntimeError{}}} =
               SquidMesh.start_run(
                 InvoiceReminderWorkflow,
                 %{account_id: "acct_123", invoice_id: "inv_456"},
                 repo: Repo,
                 execution: [name: MissingOban]
               )

      assert Repo.aggregate(RunRecord, :count, :id) == before_count
    end
  end

  describe "cron trigger activation" do
    test "validates cron plugin workflows before startup" do
      assert :ok = SquidMesh.Plugins.Cron.validate(workflows: [DailyStandupWorkflow])

      assert {:error, message} =
               SquidMesh.Plugins.Cron.validate(workflows: [InvoiceReminderWorkflow])

      assert message =~ "must define a cron trigger"
    end

    test "starts a cron workflow run from an Oban cron job" do
      job = %Oban.Job{
        args: %{
          "workflow" => "Elixir.SquidMeshTest.DailyStandupWorkflow",
          "trigger" => "daily_standup"
        }
      }

      assert :ok = CronTriggerWorker.perform(job)

      assert_enqueued(
        worker: SquidMesh.Workers.StepWorker,
        queue: "squid_mesh",
        args: %{"step" => "announce_prompt"}
      )

      assert [%PersistedRun{} = persisted_run] = Repo.all(PersistedRun)

      assert persisted_run.workflow == "Elixir.SquidMeshTest.DailyStandupWorkflow"
      assert persisted_run.trigger == "daily_standup"
      assert persisted_run.input["team_id"] == "backend"
      assert is_binary(persisted_run.input["prompt_date"])
    end
  end

  describe "inspect_run/2" do
    test "fetches a persisted run by id" do
      assert {:ok, created_run} =
               SquidMesh.start_run(
                 InvoiceReminderWorkflow,
                 %{account_id: "acct_123", invoice_id: "inv_123"},
                 repo: Repo
               )

      assert {:ok, %Run{} = inspected_run} = SquidMesh.inspect_run(created_run.id, repo: Repo)

      assert inspected_run == created_run
    end

    test "returns not found when the run does not exist" do
      assert {:error, :not_found} =
               SquidMesh.inspect_run(Ecto.UUID.generate(), repo: Repo)
    end

    test "returns stable workflow and step identifiers from persisted runs" do
      assert {:ok, created_run} =
               SquidMesh.start_run(
                 InvoiceReminderWorkflow,
                 %{account_id: "acct_123", invoice_id: "inv_456"},
                 repo: Repo
               )

      persisted_run = Repo.get!(RunRecord, created_run.id)

      assert persisted_run.workflow == "Elixir.SquidMeshTest.InvoiceReminderWorkflow"
      assert persisted_run.current_step == "load_invoice"

      assert {:ok, inspected_run} = SquidMesh.inspect_run(created_run.id, repo: Repo)

      assert inspected_run.workflow == InvoiceReminderWorkflow
      assert inspected_run.trigger == :invoice_delivery
      assert inspected_run.current_step == :load_invoice
    end

    test "optionally includes step and attempt history" do
      assert {:ok, created_run} =
               SquidMesh.start_run(
                 InvoiceReminderWorkflow,
                 %{account_id: "acct_123", invoice_id: "inv_123"},
                 repo: Repo
               )

      assert %{success: 2, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      assert {:ok, inspected_run} =
               SquidMesh.inspect_run(created_run.id, include_history: true, repo: Repo)

      assert [%PublicStepRun{}, %PublicStepRun{}] = inspected_run.step_runs

      assert Enum.map(inspected_run.step_runs, &{&1.step, &1.status}) == [
               {:load_invoice, :completed},
               {:send_email, :completed}
             ]

      assert Enum.all?(inspected_run.step_runs, fn step_run ->
               match?([%PublicStepAttempt{}], step_run.attempts)
             end)

      assert Enum.map(inspected_run.step_runs, fn step_run ->
               {step_run.step, Enum.map(step_run.attempts, & &1.attempt_number)}
             end) == [
               {:load_invoice, [1]},
               {:send_email, [1]}
             ]
    end
  end

  describe "list_runs/2" do
    test "returns runs newest first" do
      assert {:ok, first_run} =
               SquidMesh.start_run(
                 InvoiceReminderWorkflow,
                 %{account_id: "acct_123", invoice_id: "inv_123"},
                 repo: Repo
               )

      Process.sleep(1)

      assert {:ok, second_run} =
               SquidMesh.start_run(PaymentRecoveryWorkflow, %{account_id: "acct_456"}, repo: Repo)

      assert {:ok, runs} = SquidMesh.list_runs([], repo: Repo)

      assert Enum.map(runs, & &1.id) == [second_run.id, first_run.id]
    end

    test "filters runs by workflow" do
      assert {:ok, _first_run} =
               SquidMesh.start_run(
                 InvoiceReminderWorkflow,
                 %{account_id: "acct_123", invoice_id: "inv_123"},
                 repo: Repo
               )

      assert {:ok, second_run} =
               SquidMesh.start_run(PaymentRecoveryWorkflow, %{account_id: "acct_456"}, repo: Repo)

      assert {:ok, runs} =
               SquidMesh.list_runs([workflow: PaymentRecoveryWorkflow], repo: Repo)

      assert Enum.map(runs, & &1.id) == [second_run.id]
      assert Enum.map(runs, & &1.workflow) == [PaymentRecoveryWorkflow]
    end

    test "filters runs by status" do
      assert {:ok, pending_run} =
               SquidMesh.start_run(
                 InvoiceReminderWorkflow,
                 %{account_id: "acct_123", invoice_id: "inv_123"},
                 repo: Repo
               )

      assert {:ok, _failed_run} = RunStore.transition_run(Repo, pending_run.id, :failed)

      assert {:ok, runs} = SquidMesh.list_runs([status: :failed], repo: Repo)

      assert Enum.map(runs, & &1.id) == [pending_run.id]
      assert Enum.map(runs, & &1.status) == [:failed]
    end

    test "limits the number of returned runs" do
      assert {:ok, _first_run} =
               SquidMesh.start_run(
                 InvoiceReminderWorkflow,
                 %{account_id: "acct_123", invoice_id: "inv_123"},
                 repo: Repo
               )

      Process.sleep(1)

      assert {:ok, second_run} =
               SquidMesh.start_run(
                 InvoiceReminderWorkflow,
                 %{account_id: "acct_456", invoice_id: "inv_456"},
                 repo: Repo
               )

      assert {:ok, runs} = SquidMesh.list_runs([limit: 1], repo: Repo)

      assert Enum.map(runs, & &1.id) == [second_run.id]
    end
  end

  describe "cancel_run/2" do
    test "cancels pending runs through the public API" do
      assert {:ok, run} =
               SquidMesh.start_run(
                 InvoiceReminderWorkflow,
                 %{account_id: "acct_123", invoice_id: "inv_123"},
                 repo: Repo
               )

      assert {:ok, cancelled_run} = SquidMesh.cancel_run(run.id, repo: Repo)

      assert cancelled_run.id == run.id
      assert cancelled_run.status == :cancelled
    end

    test "marks active runs as cancelling through the public API" do
      assert {:ok, run} =
               SquidMesh.start_run(
                 InvoiceReminderWorkflow,
                 %{account_id: "acct_123", invoice_id: "inv_123"},
                 repo: Repo
               )

      assert {:ok, running_run} = RunStore.transition_run(Repo, run.id, :running)
      assert {:ok, cancelling_run} = SquidMesh.cancel_run(running_run.id, repo: Repo)

      assert cancelling_run.status == :cancelling
    end

    test "returns not found for missing runs" do
      assert {:error, :not_found} = SquidMesh.cancel_run(Ecto.UUID.generate(), repo: Repo)
    end
  end

  describe "replay_run/2" do
    test "creates a new run linked to the source run through the public API" do
      assert {:ok, source_run} =
               SquidMesh.start_run(
                 InvoiceReminderWorkflow,
                 %{account_id: "acct_123", invoice_id: "inv_123"},
                 repo: Repo
               )

      assert {:ok, replay_run} = SquidMesh.replay_run(source_run.id, repo: Repo)

      assert replay_run.id != source_run.id
      assert replay_run.workflow == InvoiceReminderWorkflow
      assert replay_run.trigger == :invoice_delivery
      assert replay_run.status == :pending
      assert replay_run.payload == source_run.payload
      assert replay_run.current_step == :load_invoice
      assert replay_run.replayed_from_run_id == source_run.id
    end

    test "returns not found when replaying a missing run" do
      assert {:error, :not_found} = SquidMesh.replay_run(Ecto.UUID.generate(), repo: Repo)
    end

    test "rolls back replay creation when dispatching the replayed run fails" do
      assert {:ok, source_run} =
               RunStore.create_run(
                 Repo,
                 InvoiceReminderWorkflow,
                 %{account_id: "acct_123", invoice_id: "inv_123"}
               )

      before_count = Repo.aggregate(RunRecord, :count, :id)

      assert {:error, {:dispatch_failed, %RuntimeError{}}} =
               SquidMesh.replay_run(
                 source_run.id,
                 repo: Repo,
                 execution: [name: MissingOban]
               )

      assert Repo.aggregate(RunRecord, :count, :id) == before_count
    end
  end
end
