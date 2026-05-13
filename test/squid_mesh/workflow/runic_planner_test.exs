defmodule SquidMesh.Workflow.RunicPlannerTest do
  use ExUnit.Case

  alias SquidMesh.Workflow.Info
  alias SquidMesh.Workflow.RunicPlanner

  defmodule LoadAccount do
    use SquidMesh.Step,
      name: :load_account,
      input_schema: [account_id: [type: :string, required: true]],
      output_schema: [account: [type: :map, required: true]]

    @impl true
    def run(_input, _context), do: {:ok, %{account: %{id: "acct_123"}}}
  end

  defmodule LoadInvoice do
    use SquidMesh.Step,
      name: :load_invoice,
      input_schema: [invoice_id: [type: :string, required: true]],
      output_schema: [invoice: [type: :map, required: true]]

    @impl true
    def run(_input, _context), do: {:ok, %{invoice: %{id: "inv_123"}}}
  end

  defmodule SendEmail do
    use SquidMesh.Step,
      name: :send_email,
      input_schema: [
        account: [type: :map, required: true],
        invoice: [type: :map, required: false]
      ],
      output_schema: [delivery: [type: :map, required: true]]

    @impl true
    def run(_input, _context), do: {:ok, %{delivery: %{status: "sent"}}}
  end

  defmodule LinearWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field :account_id, :string
        end
      end

      step :load_account, LoadAccount
      step :send_email, SendEmail

      transition :load_account, on: :ok, to: :send_email
      transition :send_email, on: :ok, to: :complete
    end
  end

  defmodule BranchingWorkflow do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field :account_id, :string
          field :invoice_id, :string
        end
      end

      step :load_account, LoadAccount
      step :load_invoice, LoadInvoice
      step :send_email, SendEmail, after: [:load_account, :load_invoice]
    end
  end

  test "exposes a normalized workflow spec for planner persistence" do
    spec = Info.spec(LinearWorkflow)

    assert spec.workflow == LinearWorkflow
    assert spec.entry_steps == [:load_account]

    assert spec.triggers == [
             %{
               name: :manual,
               type: :manual,
               config: %{},
               payload: [%{name: :account_id, type: :string, opts: []}]
             }
           ]

    assert Enum.map(spec.steps, &Map.take(&1, [:name, :module, :opts])) == [
             %{name: :load_account, module: LoadAccount, opts: []},
             %{name: :send_email, module: SendEmail, opts: []}
           ]

    assert spec.transitions == [
             %{from: :load_account, on: :ok, to: :send_email},
             %{from: :send_email, on: :ok, to: :complete}
           ]

    rebuilt_spec = :erlang.binary_to_term(:erlang.term_to_binary(spec))

    assert rebuilt_spec == spec

    assert {:ok, planner} = RunicPlanner.new(rebuilt_spec)
    assert {:ok, _planned, [%{step: :load_account}]} = RunicPlanner.plan(planner, %{})
  end

  test "plans a linear workflow through Runic without executing step actions" do
    {:ok, planner} = RunicPlanner.new(LinearWorkflow)
    assert %Runic.Workflow{} = planner.runic_workflow

    {:ok, planned, [load_account]} =
      RunicPlanner.plan(planner, %{account_id: "acct_123"})

    assert load_account.step == :load_account
    assert load_account.metadata.contract == :squid_mesh_step

    {:ok, after_load} =
      RunicPlanner.apply_result(planned, load_account, {:ok, %{account: %{id: "acct_123"}}})

    {:ok, _planned, [send_email]} = RunicPlanner.plan(after_load)

    assert send_email.step == :send_email
    assert send_email.input == %{account: %{id: "acct_123"}}
  end

  test "plans dependency branches and unlocks joins after completed runnable results" do
    {:ok, planner} = RunicPlanner.new(BranchingWorkflow)

    {:ok, planned, runnables} =
      RunicPlanner.plan(planner, %{account_id: "acct_123", invoice_id: "inv_123"})

    assert Enum.map(runnables, & &1.step) == [:load_account, :load_invoice]

    [load_account, load_invoice] = runnables

    {:ok, planned} =
      RunicPlanner.apply_result(planned, load_account, {:ok, %{account: %{id: "acct_123"}}})

    {:ok, planned} =
      RunicPlanner.apply_result(planned, load_invoice, {:ok, %{invoice: %{id: "inv_123"}}})

    {:ok, _planned, [send_email]} = RunicPlanner.plan(planned)

    assert send_email.step == :send_email

    assert send_email.input == %{
             account: %{id: "acct_123"},
             invoice: %{id: "inv_123"}
           }
  end
end
