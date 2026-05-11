defmodule SquidMeshTest do
  use SquidMesh.DataCase

  alias SquidMesh.Persistence.Run, as: RunRecord
  alias SquidMesh.Persistence.Run, as: PersistedRun
  alias SquidMesh.Persistence.StepRun, as: StepRunRecord
  alias SquidMesh.Run
  alias SquidMesh.RunStore
  alias SquidMesh.Runtime.Unblocker
  alias SquidMesh.StepAttempt, as: PublicStepAttempt
  alias SquidMesh.StepRun, as: PublicStepRun
  alias SquidMesh.RunStepState
  alias SquidMesh.TestSupport.LazyWorkflow
  alias SquidMesh.Workers.CronTriggerWorker
  alias SquidMesh.Workers.StepWorker
  alias Oban.Job

  defmodule InvoiceReminderWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :invoice_delivery do
        manual()

        payload do
          field :account_id, :string
          field :invoice_id, :string
        end
      end

      step :load_invoice, InvoiceReminderWorkflow.LoadInvoice
      step :send_email, InvoiceReminderWorkflow.SendEmail, retry: [max_attempts: 3]

      transition :load_invoice, on: :ok, to: :send_email
      transition :send_email, on: :ok, to: :complete
    end
  end

  defmodule PaymentRecoveryWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :gateway_recovery do
        manual()

        payload do
          field :account_id, :string
        end
      end

      step :check_gateway, PaymentRecoveryWorkflow.CheckGateway, retry: [max_attempts: 2]
      transition :check_gateway, on: :ok, to: :complete
    end
  end

  defmodule ReorderedWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :invoice_delivery do
        manual()

        payload do
          field :account_id, :string
        end
      end

      step :send_email, ReorderedWorkflow.SendEmail
      step :load_invoice, ReorderedWorkflow.LoadInvoice

      transition :load_invoice, on: :ok, to: :send_email
      transition :send_email, on: :ok, to: :complete
    end
  end

  defmodule IrreversibleWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :payment_capture do
        manual()

        payload do
          field(:account_id, :string)
        end
      end

      step(:load_account, IrreversibleWorkflow.LoadAccount)
      step(:capture_payment, IrreversibleWorkflow.CapturePayment, irreversible: true)

      transition(:load_account, on: :ok, to: :capture_payment)
      transition(:capture_payment, on: :ok, to: :complete)
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

  defmodule IrreversibleWorkflow.LoadAccount do
    use Jido.Action,
      name: "load_account",
      description: "Loads account details",
      schema: [account_id: [type: :string, required: true]]

    @impl true
    def run(%{account_id: account_id}, _context) do
      {:ok, %{account: %{id: account_id}}}
    end
  end

  defmodule IrreversibleWorkflow.CapturePayment do
    use Jido.Action,
      name: "capture_payment",
      description: "Captures a payment",
      schema: [account: [type: :map, required: true]]

    @impl true
    def run(%{account: account}, _context) do
      {:ok, %{payment: %{account_id: account.id, status: "captured"}}}
    end
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
          field :team_id, :string, default: "backend"
          field :prompt_date, :string, default: {:today, :iso8601}
          field :invoice_id, :string
        end
      end

      step :deliver_invoice, WorkflowWithPayloadDefaults.DeliverInvoice
      transition :deliver_invoice, on: :ok, to: :complete
    end
  end

  defmodule DailyStandupWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :daily_standup do
        cron "@reboot", timezone: "Etc/UTC"

        payload do
          field :team_id, :string, default: "backend"
          field :prompt_date, :string, default: {:today, :iso8601}
        end
      end

      step :announce_prompt, :log, message: "posting daily standup"
      transition :announce_prompt, on: :ok, to: :complete
    end
  end

  defmodule ManualAndScheduledDigestWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual_digest do
        manual()

        payload do
          field :chat_id, :integer
        end
      end

      trigger :scheduled_digest do
        cron "@reboot", timezone: "Etc/UTC"

        payload do
          field :window_start_at, :string, default: {:today, :iso8601}
        end
      end

      step :announce_prompt, :log, message: "posting digest"
      transition :announce_prompt, on: :ok, to: :complete
    end
  end

  defmodule PauseWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field :account_id, :string
        end
      end

      step :wait_for_approval, :pause
      step :record_delivery, :log, message: "delivery recorded", level: :info

      transition :wait_for_approval, on: :ok, to: :record_delivery
      transition :record_delivery, on: :ok, to: :complete
    end
  end

  defmodule ApprovalWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field :account_id, :string
        end
      end

      approval_step :wait_for_review, output: :approval
      step :record_approval, :log, message: "approval recorded", level: :info
      step :record_rejection, :log, message: "rejection recorded", level: :warning

      transition :wait_for_review, on: :ok, to: :record_approval
      transition :wait_for_review, on: :error, to: :record_rejection
      transition :record_approval, on: :ok, to: :complete
      transition :record_rejection, on: :ok, to: :complete
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
      assert config.stale_step_timeout == :disabled
    end

    test "allows host applications to override execution settings" do
      overrides = [
        repo: SquidMeshTest.Repo,
        execution: [name: MyApp.Oban, queue: :workflows, stale_step_timeout: 60_000]
      ]

      assert {:ok, config} = SquidMesh.config(overrides)

      assert config.execution_name == MyApp.Oban
      assert config.execution_queue == :workflows
      assert config.stale_step_timeout == 60_000
    end

    test "treats nil execution settings as defaults" do
      assert {:ok, config} = SquidMesh.config(repo: SquidMeshTest.Repo, execution: nil)

      assert config.execution_name == Oban
      assert config.execution_queue == :squid_mesh
      assert config.stale_step_timeout == :disabled
    end

    test "reports non-keyword execution settings" do
      assert {:error, {:invalid_config, [execution: %{queue: :workflows}]}} =
               SquidMesh.config(repo: SquidMeshTest.Repo, execution: %{queue: :workflows})

      assert {:error, {:invalid_config, [execution: [:bad]]}} =
               SquidMesh.config(repo: SquidMeshTest.Repo, execution: [:bad])
    end

    test "reports missing required configuration keys" do
      original_repo = Application.get_env(:squid_mesh, :repo)

      on_exit(fn ->
        Application.put_env(:squid_mesh, :repo, original_repo)
      end)

      Application.delete_env(:squid_mesh, :repo)

      assert {:error, {:missing_config, [:repo]}} = SquidMesh.config()
    end

    test "reports invalid stale step timeout settings" do
      assert {:error, {:invalid_config, [stale_step_timeout: -1]}} =
               SquidMesh.config(
                 repo: SquidMeshTest.Repo,
                 execution: [stale_step_timeout: -1]
               )
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
      assert :ok = SquidMesh.Plugins.Cron.validate(workflows: [ManualAndScheduledDigestWorkflow])

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

    test "starts a selected cron trigger from a multi-trigger workflow" do
      job = %Oban.Job{
        args: %{
          "workflow" => "Elixir.SquidMeshTest.ManualAndScheduledDigestWorkflow",
          "trigger" => "scheduled_digest"
        }
      }

      assert :ok = CronTriggerWorker.perform(job)

      assert [%PersistedRun{} = persisted_run] = Repo.all(PersistedRun)

      assert persisted_run.workflow ==
               "Elixir.SquidMeshTest.ManualAndScheduledDigestWorkflow"

      assert persisted_run.trigger == "scheduled_digest"
      assert is_binary(persisted_run.input["window_start_at"])
      refute Map.has_key?(persisted_run.input, "chat_id")
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

    test "returns a structured error for malformed run ids" do
      assert {:error, :invalid_run_id} = SquidMesh.inspect_run("not-a-uuid", repo: Repo)
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

      assert Enum.map(inspected_run.steps, &{&1.step, &1.status, &1.depends_on}) == [
               {:load_invoice, :completed, []},
               {:send_email, :completed, []}
             ]

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

      assert inspected_run.audit_events == []
    end

    test "surfaces paused and resumed audit events for manual pause workflows" do
      assert {:ok, run} =
               SquidMesh.start_run(PauseWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "wait_for_approval"}
               })

      assert {:ok, paused_run} =
               SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)

      assert paused_run.status == :paused

      assert Enum.map(paused_run.audit_events, &{&1.type, &1.step, &1.actor}) == [
               {:paused, :wait_for_approval, nil}
             ]

      assert {:ok, resumed_run} =
               SquidMesh.unblock_run(
                 run.id,
                 %{
                   actor: "ops_123",
                   comment: "resume requested",
                   metadata: %{ticket: "ops-123"}
                 },
                 repo: Repo
               )

      assert resumed_run.status == :running

      assert %{success: success, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      assert success >= 1

      assert {:ok, completed_run} =
               SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)

      assert Enum.map(completed_run.audit_events, &{&1.type, &1.step, &1.actor, &1.comment}) == [
               {:paused, :wait_for_approval, nil, nil},
               {:resumed, :wait_for_approval, "ops_123", "resume requested"}
             ]

      assert Enum.map(completed_run.audit_events, & &1.metadata) == [
               nil,
               %{ticket: "ops-123"}
             ]
    end

    test "surfaces irreversible recovery policy in step history" do
      assert {:ok, created_run} =
               SquidMesh.start_run(
                 IrreversibleWorkflow,
                 %{account_id: "acct_123"},
                 repo: Repo
               )

      assert %{success: 2, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      assert {:ok, inspected_run} =
               SquidMesh.inspect_run(created_run.id, include_history: true, repo: Repo)

      assert %RunStepState{recovery: %{replay: :manual_review_required}} =
               Enum.find(inspected_run.steps, &(&1.step == :capture_payment))

      assert %PublicStepRun{recovery: %{irreversible?: true, compensatable?: false}} =
               Enum.find(inspected_run.step_runs, &(&1.step == :capture_payment))
    end

    test "surfaces paused audit events even when the workflow definition can no longer load" do
      assert {:ok, run} =
               SquidMesh.start_run(PauseWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "wait_for_approval"}
               })

      Repo.update_all(
        from(run_record in RunRecord, where: run_record.id == ^run.id),
        set: [workflow: "Elixir.Missing.Workflow"]
      )

      assert {:ok, paused_run} =
               SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)

      assert paused_run.workflow == "Elixir.Missing.Workflow"
      assert paused_run.status == :paused

      assert Enum.map(paused_run.audit_events, &{&1.type, &1.step}) == [
               {:paused, "wait_for_approval"}
             ]
    end

    test "reconstructs completed pause audit events from persisted resume metadata when the workflow definition can no longer load" do
      assert {:ok, run} =
               SquidMesh.start_run(PauseWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "wait_for_approval"}
               })

      assert {:ok, _resumed_run} =
               SquidMesh.unblock_run(run.id, %{actor: "ops_123", comment: "resume requested"},
                 repo: Repo
               )

      assert %{success: success, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      assert success >= 1

      assert {1, _rows} =
               Repo.update_all(
                 from(step_run in SquidMesh.Persistence.StepRun,
                   where:
                     step_run.run_id == ^run.id and step_run.step == "wait_for_approval" and
                       step_run.status == "completed"
                 ),
                 set: [manual: nil]
               )

      Repo.update_all(
        from(run_record in RunRecord, where: run_record.id == ^run.id),
        set: [workflow: "Elixir.Missing.Workflow"]
      )

      assert {:ok, completed_run} =
               SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)

      assert completed_run.workflow == "Elixir.Missing.Workflow"

      assert Enum.map(completed_run.audit_events, &{&1.type, &1.step, &1.actor, &1.comment}) == [
               {:paused, "wait_for_approval", nil, nil},
               {:resumed, "wait_for_approval", nil, nil}
             ]
    end

    test "reconstructs legacy approval audit events when the workflow definition can no longer load" do
      assert {:ok, run} =
               SquidMesh.start_run(ApprovalWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "wait_for_review"}
               })

      assert {:ok, _approved_run} =
               SquidMesh.approve_run(run.id, %{actor: "ops_123", comment: "approved"}, repo: Repo)

      assert %{success: success, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      assert success >= 1

      assert {1, _rows} =
               Repo.update_all(
                 from(step_run in SquidMesh.Persistence.StepRun,
                   where:
                     step_run.run_id == ^run.id and step_run.step == "wait_for_review" and
                       step_run.status == "completed"
                 ),
                 set: [manual: nil]
               )

      Repo.update_all(
        from(run_record in RunRecord, where: run_record.id == ^run.id),
        set: [workflow: "Elixir.Missing.Workflow"]
      )

      assert {:ok, completed_run} =
               SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)

      assert completed_run.workflow == "Elixir.Missing.Workflow"

      assert Enum.map(completed_run.audit_events, &{&1.type, &1.step, &1.actor, &1.comment}) == [
               {:paused, "wait_for_review", nil, nil},
               {:approved, "wait_for_review", "ops_123", "approved"}
             ]
    end

    test "falls back to legacy approval output when persisted manual audit metadata is corrupted" do
      assert {:ok, run} =
               SquidMesh.start_run(ApprovalWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "wait_for_review"}
               })

      assert {:ok, _approved_run} =
               SquidMesh.approve_run(run.id, %{actor: "ops_123", comment: "approved"}, repo: Repo)

      assert %{success: success, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      assert success >= 1

      assert {1, _rows} =
               Repo.update_all(
                 from(step_run in SquidMesh.Persistence.StepRun,
                   where:
                     step_run.run_id == ^run.id and step_run.step == "wait_for_review" and
                       step_run.status == "completed"
                 ),
                 set: [manual: %{"event" => "unknown", "actor" => "ignored"}]
               )

      assert {:ok, completed_run} =
               SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)

      assert Enum.map(completed_run.audit_events, &{&1.type, &1.step, &1.actor, &1.comment}) == [
               {:paused, :wait_for_review, nil, nil},
               {:approved, :wait_for_review, "ops_123", "approved"}
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

    test "returns a structured error for malformed run ids" do
      assert {:error, :invalid_run_id} = SquidMesh.cancel_run("not-a-uuid", repo: Repo)
    end

    test "finalizes paused step history when cancelling a paused run" do
      assert {:ok, run} =
               SquidMesh.start_run(PauseWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "wait_for_approval"}
               })

      assert {:ok, cancelled_run} = SquidMesh.cancel_run(run.id, repo: Repo)
      assert cancelled_run.status == :cancelled

      assert {:ok, inspected_run} =
               SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)

      paused_step = Enum.find(inspected_run.step_runs, &(&1.step == :wait_for_approval))

      assert paused_step.status == :failed
      assert paused_step.output == nil

      assert paused_step.last_error == %{
               message: "run cancelled while paused",
               reason: "cancelled"
             }

      assert Enum.map(paused_step.attempts, &{&1.attempt_number, &1.status, &1.error}) == [
               {1, :failed, %{message: "run cancelled while paused", reason: "cancelled"}}
             ]
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

    test "returns a structured error for malformed run ids" do
      assert {:error, :invalid_run_id} = SquidMesh.replay_run("not-a-uuid", repo: Repo)
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

    test "blocks replay by default after completed irreversible steps" do
      assert {:ok, source_run} =
               SquidMesh.start_run(
                 IrreversibleWorkflow,
                 %{account_id: "acct_123"},
                 repo: Repo
               )

      assert %{success: 2, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      before_count = Repo.aggregate(RunRecord, :count, :id)

      assert {:error,
              {:unsafe_replay,
               %{
                 message:
                   "replay requires explicit approval after irreversible or non-compensatable steps",
                 steps: [
                   %{
                     step: :capture_payment,
                     irreversible?: true,
                     compensatable?: false,
                     replay: :manual_review_required,
                     recovery: :manual_intervention
                   }
                 ]
               }}} = SquidMesh.replay_run(source_run.id, repo: Repo)

      assert Repo.aggregate(RunRecord, :count, :id) == before_count
    end

    test "uses persisted recovery policy when checking replay safety" do
      assert {:ok, source_run} =
               SquidMesh.start_run(
                 InvoiceReminderWorkflow,
                 %{account_id: "acct_123", invoice_id: "inv_123"},
                 repo: Repo
               )

      assert %{success: 2, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      assert {1, _rows} =
               Repo.update_all(
                 from(step_run in StepRunRecord,
                   where:
                     step_run.run_id == ^source_run.id and step_run.step == "send_email" and
                       step_run.status == "completed"
                 ),
                 set: [
                   recovery: %{
                     "irreversible?" => false,
                     "compensatable?" => false,
                     "replay" => "manual_review_required",
                     "recovery" => "manual_intervention"
                   }
                 ]
               )

      assert {:error, {:unsafe_replay, %{steps: [%{step: :send_email}]}}} =
               SquidMesh.replay_run(source_run.id, repo: Repo)
    end

    test "allows replay after irreversible steps only when explicitly requested" do
      assert {:ok, source_run} =
               SquidMesh.start_run(
                 IrreversibleWorkflow,
                 %{account_id: "acct_123"},
                 repo: Repo
               )

      assert %{success: 2, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      assert {:ok, replay_run} =
               SquidMesh.replay_run(source_run.id, repo: Repo, allow_irreversible: true)

      assert replay_run.replayed_from_run_id == source_run.id
      assert replay_run.current_step == :load_account
    end

    test "does not treat non-boolean allow_irreversible values as approval" do
      assert {:ok, source_run} =
               SquidMesh.start_run(
                 IrreversibleWorkflow,
                 %{account_id: "acct_123"},
                 repo: Repo
               )

      assert %{success: 2, failure: 0} =
               Oban.drain_queue(queue: :squid_mesh, with_recursion: true)

      before_count = Repo.aggregate(RunRecord, :count, :id)

      assert {:error, {:unsafe_replay, %{steps: [%{step: :capture_payment}]}}} =
               SquidMesh.replay_run(source_run.id, repo: Repo, allow_irreversible: "true")

      assert Repo.aggregate(RunRecord, :count, :id) == before_count
    end
  end

  describe "unblock_run/2" do
    test "resumes paused runs through the public API" do
      assert {:ok, run} =
               SquidMesh.start_run(PauseWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "wait_for_approval"}
               })

      assert {:ok, paused_run} = SquidMesh.inspect_run(run.id, repo: Repo)
      assert paused_run.status == :paused

      assert {:ok, unblocked_run} = SquidMesh.unblock_run(run.id, repo: Repo)

      assert unblocked_run.id == run.id
      assert unblocked_run.status == :running
      assert unblocked_run.current_step == :record_delivery
    end

    test "rolls back unblock when dispatching the resumed step fails" do
      assert {:ok, run} =
               SquidMesh.start_run(PauseWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "wait_for_approval"}
               })

      assert {:ok, paused_run} = SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)
      assert paused_run.status == :paused

      assert {:error, {:dispatch_failed, %RuntimeError{}}} =
               SquidMesh.unblock_run(run.id, repo: Repo, execution: [name: MissingOban])

      assert {:ok, current_run} = SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)
      assert current_run.status == :paused
      assert current_run.current_step == :wait_for_approval

      paused_step = Enum.find(current_run.step_runs, &(&1.step == :wait_for_approval))
      assert paused_step.status == :running
      assert Enum.map(paused_step.attempts, & &1.status) == [:running]
    end

    test "returns not found for missing runs" do
      assert {:error, :not_found} = SquidMesh.unblock_run(Ecto.UUID.generate(), repo: Repo)
    end

    test "returns a structured error for malformed run ids" do
      assert {:error, :invalid_run_id} = SquidMesh.unblock_run("not-a-uuid", repo: Repo)
    end

    test "returns a structured error when the paused run workflow can no longer be loaded" do
      assert {:ok, run} =
               SquidMesh.start_run(PauseWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "wait_for_approval"}
               })

      Repo.update_all(
        from(run_record in RunRecord, where: run_record.id == ^run.id),
        set: [workflow: "Elixir.Missing.Workflow"]
      )

      assert {:error, {:invalid_workflow, "Elixir.Missing.Workflow"}} =
               SquidMesh.unblock_run(run.id, repo: Repo)
    end

    test "returns a structured error when the paused step no longer resolves to built-in :pause" do
      assert {:ok, run} =
               SquidMesh.start_run(PauseWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "wait_for_approval"}
               })

      Repo.update_all(
        from(run_record in RunRecord, where: run_record.id == ^run.id),
        set: [current_step: "record_delivery"]
      )

      assert {:error, {:invalid_step, :record_delivery}} =
               SquidMesh.unblock_run(run.id, repo: Repo)
    end

    test "does not mutate pause state when a stale unblock races with cancellation" do
      assert {:ok, run} =
               SquidMesh.start_run(PauseWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "wait_for_approval"}
               })

      assert {:ok, paused_run} = SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)
      assert paused_run.status == :paused

      assert {:ok, cancelled_run} = SquidMesh.cancel_run(run.id, repo: Repo)
      assert cancelled_run.status == :cancelled

      assert {:error, {:invalid_transition, :cancelled, :running}} =
               Unblocker.unblock(SquidMesh.config!(repo: Repo), paused_run)

      assert {:ok, current_run} = SquidMesh.inspect_run(run.id, include_history: true, repo: Repo)
      assert current_run.status == :cancelled

      paused_step = Enum.find(current_run.step_runs, &(&1.step == :wait_for_approval))
      assert paused_step.status == :failed
      assert paused_step.output == nil

      assert Enum.map(paused_step.attempts, &{&1.status, &1.error}) == [
               {:failed, %{message: "run cancelled while paused", reason: "cancelled"}}
             ]
    end
  end

  describe "approve_run/3 and reject_run/3" do
    test "approves paused approval runs through the public API" do
      assert {:ok, run} =
               SquidMesh.start_run(ApprovalWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "wait_for_review"}
               })

      assert {:ok, paused_run} = SquidMesh.inspect_run(run.id, repo: Repo)
      assert paused_run.status == :paused

      assert {:ok, approved_run} =
               SquidMesh.approve_run(
                 run.id,
                 %{actor: "ops_123", comment: "approved"},
                 repo: Repo
               )

      assert approved_run.id == run.id
      assert approved_run.status == :running
      assert approved_run.current_step == :record_approval
    end

    test "rejects paused approval runs through the public API" do
      assert {:ok, run} =
               SquidMesh.start_run(ApprovalWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "wait_for_review"}
               })

      assert {:ok, paused_run} = SquidMesh.inspect_run(run.id, repo: Repo)
      assert paused_run.status == :paused

      assert {:ok, rejected_run} =
               SquidMesh.reject_run(
                 run.id,
                 %{actor: "ops_456", comment: "rejected"},
                 repo: Repo
               )

      assert rejected_run.id == run.id
      assert rejected_run.status == :running
      assert rejected_run.current_step == :record_rejection
    end

    test "returns a structured error when the approval workflow can no longer be loaded" do
      assert {:ok, run} =
               SquidMesh.start_run(ApprovalWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "wait_for_review"}
               })

      Repo.update_all(
        from(run_record in RunRecord, where: run_record.id == ^run.id),
        set: [workflow: "Elixir.Missing.Workflow"]
      )

      assert {:error, {:invalid_workflow, "Elixir.Missing.Workflow"}} =
               SquidMesh.approve_run(run.id, %{actor: "ops_123"}, repo: Repo)
    end

    test "returns a structured error for malformed approval run ids" do
      assert {:error, :invalid_run_id} =
               SquidMesh.approve_run("not-a-uuid", %{actor: "ops_123"}, repo: Repo)
    end

    test "returns a structured error for malformed rejection run ids" do
      assert {:error, :invalid_run_id} =
               SquidMesh.reject_run("not-a-uuid", %{actor: "ops_123"}, repo: Repo)
    end

    test "rejects empty actor maps for approval decisions" do
      assert {:ok, run} =
               SquidMesh.start_run(ApprovalWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert :ok =
               StepWorker.perform(%Job{
                 args: %{"run_id" => run.id, "step" => "wait_for_review"}
               })

      assert {:error, {:invalid_review, %{actor: :required}}} =
               SquidMesh.approve_run(run.id, %{actor: %{}}, repo: Repo)
    end
  end
end
