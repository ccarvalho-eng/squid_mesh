defmodule SquidMesh.RunStoreTest do
  use SquidMesh.DataCase

  alias SquidMesh.Persistence.Run, as: RunRecord
  alias SquidMesh.RunStore

  defmodule InvoiceReminderWorkflow do
    use SquidMesh.Workflow

    workflow do
      input do
        field(:account_id, :string)
      end

      step(:load_invoice, InvoiceReminderWorkflow.LoadInvoice)
      transition(:load_invoice, on: :ok, to: :complete)
      retry(:load_invoice, max_attempts: 1)
    end
  end

  describe "transition_run/4" do
    test "persists a valid transition" do
      assert {:ok, run} =
               RunStore.create_run(Repo, InvoiceReminderWorkflow, %{account_id: "acct_123"})

      assert {:ok, transitioned_run} =
               RunStore.transition_run(Repo, run.id, :running, %{current_step: :load_invoice})

      assert transitioned_run.id == run.id
      assert transitioned_run.status == :running
      assert transitioned_run.current_step == :load_invoice
    end

    test "persists transition metadata alongside the status change" do
      assert {:ok, run} =
               RunStore.create_run(Repo, InvoiceReminderWorkflow, %{account_id: "acct_123"})

      error = %{message: "gateway timeout"}

      assert {:ok, transitioned_run} =
               RunStore.transition_run(Repo, run.id, :failed, %{
                 last_error: error,
                 context: %{attempt: 3}
               })

      assert transitioned_run.status == :failed
      assert transitioned_run.last_error == error
      assert transitioned_run.context == %{attempt: 3}
    end

    test "rejects invalid transitions and keeps the persisted state unchanged" do
      assert {:ok, run} =
               RunStore.create_run(Repo, InvoiceReminderWorkflow, %{account_id: "acct_123"})

      assert {:error, {:invalid_transition, :pending, :completed}} =
               RunStore.transition_run(Repo, run.id, :completed)

      assert {:ok, persisted_run} = RunStore.get_run(Repo, run.id)

      assert persisted_run.status == :pending
      assert persisted_run.current_step == :load_invoice
    end

    test "returns not found when the run does not exist" do
      assert {:error, :not_found} =
               RunStore.transition_run(Repo, Ecto.UUID.generate(), :running)
    end
  end

  describe "cancel_run/2" do
    test "cancels pending runs immediately" do
      assert {:ok, run} =
               RunStore.create_run(Repo, InvoiceReminderWorkflow, %{account_id: "acct_123"})

      assert {:ok, cancelled_run} = RunStore.cancel_run(Repo, run.id)

      assert cancelled_run.status == :cancelled
      assert RunStore.schedule_next_step?(cancelled_run) == false
    end

    test "marks active runs as cancelling and prevents future scheduling" do
      assert {:ok, run} =
               RunStore.create_run(Repo, InvoiceReminderWorkflow, %{account_id: "acct_123"})

      assert {:ok, running_run} = RunStore.transition_run(Repo, run.id, :running)
      assert {:ok, cancelling_run} = RunStore.cancel_run(Repo, running_run.id)

      assert cancelling_run.status == :cancelling
      assert RunStore.schedule_next_step?(cancelling_run) == false
    end

    test "rejects cancellation for terminal runs" do
      assert {:ok, run} =
               RunStore.create_run(Repo, InvoiceReminderWorkflow, %{account_id: "acct_123"})

      assert {:ok, failed_run} = RunStore.transition_run(Repo, run.id, :failed)

      assert {:error, {:invalid_transition, :failed, :cancelling}} =
               RunStore.cancel_run(Repo, failed_run.id)
    end
  end

  describe "get_run/2" do
    test "returns stable workflow and step identifiers after reloading from persistence" do
      assert {:ok, run} =
               RunStore.create_run(Repo, InvoiceReminderWorkflow, %{account_id: "acct_123"})

      persisted_run = Repo.get!(RunRecord, run.id)

      assert persisted_run.workflow == "Elixir.SquidMesh.RunStoreTest.InvoiceReminderWorkflow"
      assert persisted_run.current_step == "load_invoice"

      assert {:ok, loaded_run} = RunStore.get_run(Repo, run.id)

      assert loaded_run.workflow == InvoiceReminderWorkflow
      assert loaded_run.current_step == :load_invoice
    end
  end
end
