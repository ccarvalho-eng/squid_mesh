defmodule SquidMeshTest do
  use SquidMesh.DataCase

  alias SquidMesh.Persistence.Run, as: RunRecord
  alias SquidMesh.Run
  alias SquidMesh.RunStore
  alias SquidMesh.TestSupport.LazyWorkflow

  defmodule InvoiceReminderWorkflow do
    use SquidMesh.Workflow

    workflow do
      input do
        field(:account_id, :string)
        field(:invoice_id, :string)
      end

      step(:load_invoice, InvoiceReminderWorkflow.LoadInvoice)
      step(:send_email, InvoiceReminderWorkflow.SendEmail)

      transition(:load_invoice, on: :ok, to: :send_email)
      transition(:send_email, on: :ok, to: :complete)

      retry(:send_email, max_attempts: 3)
    end
  end

  defmodule PaymentRecoveryWorkflow do
    use SquidMesh.Workflow

    workflow do
      input do
        field(:account_id, :string)
      end

      step(:check_gateway, PaymentRecoveryWorkflow.CheckGateway)
      transition(:check_gateway, on: :ok, to: :complete)
      retry(:check_gateway, max_attempts: 2)
    end
  end

  defmodule ReorderedWorkflow do
    use SquidMesh.Workflow

    workflow do
      input do
        field(:account_id, :string)
      end

      step(:send_email, ReorderedWorkflow.SendEmail)
      step(:load_invoice, ReorderedWorkflow.LoadInvoice)

      transition(:load_invoice, on: :ok, to: :send_email)
      transition(:send_email, on: :ok, to: :complete)
    end
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
      assert {:error, {:missing_config, [:repo]}} = SquidMesh.config()
    end
  end

  describe "start_run/3" do
    test "persists a new run and returns the public run shape" do
      input = %{account_id: "acct_123", invoice_id: "inv_456"}

      assert {:ok, %Run{} = run} =
               SquidMesh.start_run(InvoiceReminderWorkflow, input, repo: Repo)

      assert run.workflow == InvoiceReminderWorkflow
      assert run.status == :pending
      assert run.input == input
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

    test "rejects non-map input payloads" do
      assert {:error, {:invalid_input, :expected_map}} =
               SquidMesh.start_run(InvoiceReminderWorkflow, [:not_a_map], repo: Repo)
    end

    test "starts from the semantic entry step rather than declaration order" do
      assert {:ok, run} =
               SquidMesh.start_run(ReorderedWorkflow, %{account_id: "acct_123"}, repo: Repo)

      assert run.current_step == :load_invoice
    end

    test "rejects missing required input fields" do
      assert {:error, {:invalid_input, %{missing_fields: [:invoice_id]}}} =
               SquidMesh.start_run(InvoiceReminderWorkflow, %{account_id: "acct_123"}, repo: Repo)
    end

    test "rejects undeclared input fields" do
      assert {:error, {:invalid_input, %{unknown_fields: [:unexpected]}}} =
               SquidMesh.start_run(
                 InvoiceReminderWorkflow,
                 %{account_id: "acct_123", invoice_id: "inv_456", unexpected: true},
                 repo: Repo
               )
    end

    test "rejects input fields with invalid types" do
      assert {:error, {:invalid_input, %{invalid_types: %{invoice_id: :string}}}} =
               SquidMesh.start_run(
                 InvoiceReminderWorkflow,
                 %{account_id: "acct_123", invoice_id: 123},
                 repo: Repo
               )
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
      assert inspected_run.current_step == :load_invoice
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
end
