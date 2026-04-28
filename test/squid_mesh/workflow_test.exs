defmodule SquidMesh.WorkflowTest do
  use ExUnit.Case

  defmodule InvoiceReminder do
    use SquidMesh.Workflow

    workflow do
      trigger :manual do
        manual()

        payload do
          field(:account_id, :string)
          field(:invoice_id, :string)
        end
      end

      step(:load_invoice, InvoiceReminder.LoadInvoice)
      step(:send_email, InvoiceReminder.SendEmail)
      step(:record_delivery, InvoiceReminder.RecordDelivery)

      transition(:load_invoice, on: :ok, to: :send_email)
      transition(:send_email, on: :ok, to: :record_delivery)
      transition(:record_delivery, on: :ok, to: :complete)

      retry(:send_email, max_attempts: 3)
    end
  end

  test "exposes a declarative workflow definition" do
    definition = InvoiceReminder.workflow_definition()

    assert definition.triggers == [
             %{
               name: :manual,
               type: :manual,
               config: %{},
               payload: [
                 %{name: :account_id, type: :string, opts: []},
                 %{name: :invoice_id, type: :string, opts: []}
               ]
             }
           ]

    assert definition.payload == [
             %{name: :account_id, type: :string, opts: []},
             %{name: :invoice_id, type: :string, opts: []}
           ]

    assert definition.steps == [
             %{name: :load_invoice, module: InvoiceReminder.LoadInvoice, opts: []},
             %{name: :send_email, module: InvoiceReminder.SendEmail, opts: []},
             %{name: :record_delivery, module: InvoiceReminder.RecordDelivery, opts: []}
           ]

    assert definition.transitions == [
             %{from: :load_invoice, on: :ok, to: :send_email},
             %{from: :send_email, on: :ok, to: :record_delivery},
             %{from: :record_delivery, on: :ok, to: :complete}
           ]

    assert definition.retries == [
             %{step: :send_email, opts: [max_attempts: 3]}
           ]

    assert definition.entry_step == :load_invoice
  end

  test "exposes the workflow contract shape" do
    assert InvoiceReminder.__workflow__(:contract) == %{
             required: [:trigger, :step],
             optional: [:transition, :retry]
           }
  end

  test "supports introspection of definition segments" do
    assert InvoiceReminder.__workflow__(:steps) == InvoiceReminder.workflow_definition().steps
    assert InvoiceReminder.__workflow__(:payload) == InvoiceReminder.workflow_definition().payload

    assert InvoiceReminder.__workflow__(:triggers) ==
             InvoiceReminder.workflow_definition().triggers

    assert InvoiceReminder.__workflow__(:transitions) ==
             InvoiceReminder.workflow_definition().transitions

    assert InvoiceReminder.__workflow__(:retries) == InvoiceReminder.workflow_definition().retries
    assert InvoiceReminder.__workflow__(:entry_step) == :load_invoice
  end

  test "fails when no steps are declared" do
    assert_compile_error(
      """
      defmodule WorkflowWithoutSteps do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()

            payload do
              field(:account_id, :string)
            end
          end
        end
      end
      """,
      "at least one step is required"
    )
  end

  test "fails when step names are duplicated" do
    assert_compile_error(
      """
      defmodule WorkflowWithDuplicateSteps do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:send_email, WorkflowWithDuplicateSteps.SendEmail)
          step(:send_email, WorkflowWithDuplicateSteps.RecordDelivery)
        end
      end
      """,
      "duplicate step names: :send_email"
    )
  end

  test "fails when retry policy is malformed" do
    assert_compile_error(
      """
      defmodule WorkflowWithInvalidRetry do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:send_email, WorkflowWithInvalidRetry.SendEmail)
          retry(:send_email, max_attempts: 0)
        end
      end
      """,
      "retry for :send_email must define a positive :max_attempts"
    )
  end

  test "fails when retry references an unknown step" do
    assert_compile_error(
      """
      defmodule WorkflowWithUnknownRetryStep do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:send_email, WorkflowWithUnknownRetryStep.SendEmail)
          retry(:record_delivery, max_attempts: 3)
        end
      end
      """,
      "retry references unknown step: :record_delivery"
    )
  end

  test "fails when a workflow defines multiple entry steps" do
    assert_compile_error(
      """
      defmodule WorkflowWithMultipleEntrySteps do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:load_invoice, WorkflowWithMultipleEntrySteps.LoadInvoice)
          step(:send_email, WorkflowWithMultipleEntrySteps.SendEmail)
        end
      end
      """,
      "workflow must define exactly one entry step"
    )
  end

  test "fails when a workflow defines no entry step" do
    assert_compile_error(
      """
      defmodule WorkflowWithoutEntryStep do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:load_invoice, WorkflowWithoutEntryStep.LoadInvoice)
          step(:send_email, WorkflowWithoutEntryStep.SendEmail)

          transition(:load_invoice, on: :ok, to: :send_email)
          transition(:send_email, on: :ok, to: :load_invoice)
        end
      end
      """,
      "workflow must define exactly one entry step"
    )
  end

  test "fails when no triggers are declared" do
    assert_compile_error(
      """
      defmodule WorkflowWithoutTriggers do
        use SquidMesh.Workflow

        workflow do
          step(:load_invoice, WorkflowWithoutTriggers.LoadInvoice)
        end
      end
      """,
      "exactly one trigger is required"
    )
  end

  test "fails when a trigger does not define a type" do
    assert_compile_error(
      """
      defmodule WorkflowWithUntypedTrigger do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            payload do
              field(:account_id, :string)
            end
          end

          step(:load_invoice, WorkflowWithUntypedTrigger.LoadInvoice)
        end
      end
      """,
      "trigger :manual must define exactly one type"
    )
  end

  test "fails when a workflow declares more than one trigger" do
    assert_compile_error(
      """
      defmodule WorkflowWithMultipleTriggers do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          trigger :daily do
            cron("0 9 * * *", timezone: "UTC")
          end

          step(:load_invoice, WorkflowWithMultipleTriggers.LoadInvoice)
        end
      end
      """,
      "exactly one trigger is required"
    )
  end

  test "fails when a trigger declares more than one type" do
    assert_compile_error(
      """
      defmodule WorkflowWithMultipleTriggerTypes do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
            cron("0 9 * * *", timezone: "UTC")
          end

          step(:load_invoice, WorkflowWithMultipleTriggerTypes.LoadInvoice)
        end
      end
      """,
      "trigger :manual must define exactly one type"
    )
  end

  test "exposes cron trigger metadata and payload defaults" do
    module =
      compile_module("""
      defmodule WorkflowWithCronTrigger do
        use SquidMesh.Workflow

        workflow do
          trigger :daily_standup do
            cron("0 9 * * 1-5", timezone: "America/Sao_Paulo")

            payload do
              field(:team_id, :string, default: "backend")
              field(:prompt_date, :string, default: {:today, :iso8601})
            end
          end

          step(:load_team_members, WorkflowWithCronTrigger.LoadTeamMembers)
          transition(:load_team_members, on: :ok, to: :complete)
        end
      end
      """)

    assert module.workflow_definition().triggers == [
             %{
               name: :daily_standup,
               type: :cron,
               config: %{
                 expression: "0 9 * * 1-5",
                 timezone: "America/Sao_Paulo"
               },
               payload: [
                 %{name: :team_id, type: :string, opts: [default: "backend"]},
                 %{name: :prompt_date, type: :string, opts: [default: {:today, :iso8601}]}
               ]
             }
           ]
  end

  defp assert_compile_error(source, message) do
    error =
      assert_raise CompileError, fn ->
        Code.compile_string(source, "test/support/invalid_workflow.exs")
      end

    assert Exception.message(error) |> String.contains?(message)
  end

  defp compile_module(source) do
    [{module, _bytecode}] = Code.compile_string(source, "test/support/valid_workflow.exs")
    module
  end
end
