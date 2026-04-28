defmodule SquidMeshTest do
  use ExUnit.Case

  alias SquidMesh.Run
  alias SquidMesh.TestSupport.FakeRepo
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

  setup_all do
    start_supervised!(FakeRepo)
    :ok
  end

  setup do
    FakeRepo.reset()

    on_exit(fn ->
      Application.delete_env(:squid_mesh, :repo)
    end)

    :ok
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
               SquidMesh.start_run(InvoiceReminderWorkflow, input, repo: FakeRepo)

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
               SquidMesh.start_run(String, %{}, repo: FakeRepo)
    end

    test "loads workflow modules on demand before validating the contract" do
      :code.purge(LazyWorkflow)
      :code.delete(LazyWorkflow)

      refute :code.is_loaded(LazyWorkflow)

      assert {:ok, %Run{} = run} =
               SquidMesh.start_run(LazyWorkflow, %{account_id: "acct_123"}, repo: FakeRepo)

      assert run.workflow == LazyWorkflow
    end

    test "rejects non-map input payloads" do
      assert {:error, {:invalid_input, :expected_map}} =
               SquidMesh.start_run(InvoiceReminderWorkflow, [:not_a_map], repo: FakeRepo)
    end
  end

  describe "inspect_run/2" do
    test "fetches a persisted run by id" do
      assert {:ok, created_run} =
               SquidMesh.start_run(InvoiceReminderWorkflow, %{account_id: "acct_123"},
                 repo: FakeRepo
               )

      assert {:ok, %Run{} = inspected_run} = SquidMesh.inspect_run(created_run.id, repo: FakeRepo)

      assert inspected_run == created_run
    end

    test "returns not found when the run does not exist" do
      assert {:error, :not_found} =
               SquidMesh.inspect_run(Ecto.UUID.generate(), repo: FakeRepo)
    end
  end
end
