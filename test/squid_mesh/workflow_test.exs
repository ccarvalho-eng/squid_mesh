defmodule SquidMesh.WorkflowTest do
  use ExUnit.Case

  alias __MODULE__.DependencyWorkflow
  alias __MODULE__.InvoiceReminder

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
             %{
               name: :send_email,
               module: InvoiceReminder.SendEmail,
               opts: [retry: [max_attempts: 3]]
             },
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
             optional: [:transition]
           }
  end

  test "supports dependency-based step declarations with multiple entry steps" do
    definition = DependencyWorkflow.workflow_definition()

    assert definition.steps == [
             %{name: :load_account, module: DependencyWorkflow.LoadAccount, opts: []},
             %{name: :load_invoice, module: DependencyWorkflow.LoadInvoice, opts: []},
             %{
               name: :send_email,
               module: DependencyWorkflow.SendEmail,
               opts: [after: [:load_account, :load_invoice]]
             }
           ]

    assert definition.entry_steps == [:load_account, :load_invoice]
    assert definition.initial_step == :load_account
    assert definition.entry_step == nil
  end

  test "supports explicit step input and output mapping options" do
    module =
      compile_module("""
      defmodule WorkflowWithStepMappings do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()

            payload do
              field(:account_id, :string)
              field(:invoice_id, :string)
            end
          end

          step(:load_account, WorkflowWithStepMappings.LoadAccount,
            input: [:account_id],
            output: :account
          )

          transition(:load_account, on: :ok, to: :complete)
        end
      end
      """)

    assert module.workflow_definition().steps == [
             %{
               name: :load_account,
               module: Module.concat(module, LoadAccount),
               opts: [input: [:account_id], output: :account]
             }
           ]
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

  test "exposes dependency entry steps for introspection" do
    assert DependencyWorkflow.__workflow__(:entry_steps) == [:load_account, :load_invoice]
    assert DependencyWorkflow.__workflow__(:initial_step) == :load_account
    assert DependencyWorkflow.__workflow__(:entry_step) == nil
  end

  test "waits when the current dependency phase already has a failed sibling" do
    definition = DependencyWorkflow.workflow_definition()

    assert {:wait, [:load_invoice]} =
             SquidMesh.Workflow.Definition.dependency_progress(definition, %{
               load_account: :completed,
               load_invoice: :failed
             })
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

  test "fails when step retry policy is malformed" do
    assert_compile_error(
      """
      defmodule WorkflowWithInvalidRetry do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:send_email, WorkflowWithInvalidRetry.SendEmail, retry: [max_attempts: 0])
        end
      end
      """,
      "retry for :send_email must define a positive :max_attempts"
    )
  end

  test "does not expose retries when no step config defines them" do
    module =
      compile_module("""
      defmodule WorkflowWithoutRetries do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:send_email, WorkflowWithoutRetries.SendEmail)
          transition(:send_email, on: :ok, to: :complete)
        end
      end
      """)

    assert module.__workflow__(:retries) == []
  end

  test "fails when step retry is not a keyword list" do
    assert_compile_error(
      """
      defmodule WorkflowWithInvalidRetryShape do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:send_email, WorkflowWithInvalidRetryShape.SendEmail, retry: 3)
        end
      end
      """,
      "retry for :send_email must define a positive :max_attempts"
    )
  end

  test "fails when retry backoff configuration is invalid" do
    assert_compile_error(
      """
      defmodule WorkflowWithInvalidRetryBackoff do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:send_email, WorkflowWithInvalidRetryBackoff.SendEmail,
            retry: [max_attempts: 3, backoff: [type: :exponential, min: 0, max: 1_000]]
          )
        end
      end
      """,
      "retry for :send_email defines an invalid :backoff option"
    )
  end

  test "fails when step input mapping is not a non-empty atom list" do
    assert_compile_error(
      """
      defmodule WorkflowWithInvalidStepInput do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:send_email, WorkflowWithInvalidStepInput.SendEmail, input: "account_id")
        end
      end
      """,
      "step :send_email defines an invalid :input mapping"
    )
  end

  test "fails when step output mapping is not an atom" do
    assert_compile_error(
      """
      defmodule WorkflowWithInvalidStepOutput do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:send_email, WorkflowWithInvalidStepOutput.SendEmail, output: [:delivery])
        end
      end
      """,
      "step :send_email defines an invalid :output mapping"
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

  test "allows multiple entry steps when dependency execution is declared" do
    module =
      compile_module("""
      defmodule WorkflowWithMultipleDependencyRoots do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:load_account, WorkflowWithMultipleDependencyRoots.LoadAccount)
          step(:load_invoice, WorkflowWithMultipleDependencyRoots.LoadInvoice)
          step(:send_email, WorkflowWithMultipleDependencyRoots.SendEmail,
            after: [:load_account, :load_invoice]
          )
        end
      end
      """)

    assert module.__workflow__(:entry_steps) == [:load_account, :load_invoice]
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

  test "fails when a dependency references an unknown step" do
    assert_compile_error(
      """
      defmodule WorkflowWithUnknownDependency do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:load_invoice, WorkflowWithUnknownDependency.LoadInvoice)
          step(:send_email, WorkflowWithUnknownDependency.SendEmail, after: [:missing_step])
        end
      end
      """,
      "step :send_email depends on unknown step :missing_step"
    )
  end

  test "entry_steps!/2 raises a dependency-specific error when no root steps exist" do
    definition = %{
      steps: [
        %{name: :load_account, opts: [after: [:send_email]]},
        %{name: :send_email, opts: [after: [:load_account]]}
      ],
      transitions: []
    }

    assert_raise CompileError,
                 ~r/dependency-based workflow must define at least one root step/,
                 fn ->
                   SquidMesh.Workflow.Validation.entry_steps!(definition, __ENV__)
                 end
  end

  test "fails when dependency declarations contain a cycle" do
    assert_compile_error(
      """
      defmodule WorkflowWithDependencyCycle do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:load_invoice, WorkflowWithDependencyCycle.LoadInvoice, after: [:send_email])
          step(:send_email, WorkflowWithDependencyCycle.SendEmail, after: [:load_invoice])
        end
      end
      """,
      "workflow dependency graph must be acyclic"
    )
  end

  test "fails when a workflow mixes dependency joins with transitions" do
    assert_compile_error(
      """
      defmodule WorkflowWithMixedProgression do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:load_account, WorkflowWithMixedProgression.LoadAccount)
          step(:load_invoice, WorkflowWithMixedProgression.LoadInvoice)
          step(:prepare_notification, WorkflowWithMixedProgression.PrepareNotification,
            after: [:load_account, :load_invoice]
          )
          step(:record_delivery, WorkflowWithMixedProgression.RecordDelivery)

          transition(:prepare_notification, on: :ok, to: :record_delivery)
          transition(:record_delivery, on: :ok, to: :complete)
        end
      end
      """,
      "dependency-based workflows cannot declare transitions"
    )
  end

  test "fails when :after is not a list of step atoms" do
    assert_compile_error(
      """
      defmodule WorkflowWithInvalidAfterShape do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:load_invoice, WorkflowWithInvalidAfterShape.LoadInvoice)
          step(:send_email, WorkflowWithInvalidAfterShape.SendEmail, after: "load_invoice")
        end
      end
      """,
      "step :send_email defines an invalid :after dependency list"
    )
  end

  test "fails when :after is empty" do
    assert_compile_error(
      """
      defmodule WorkflowWithEmptyAfter do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:load_invoice, WorkflowWithEmptyAfter.LoadInvoice)
          step(:send_email, WorkflowWithEmptyAfter.SendEmail, after: [])
        end
      end
      """,
      "step :send_email defines an invalid :after dependency list"
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

  test "supports multiple triggers with independent payload contracts" do
    module =
      compile_module("""
      defmodule WorkflowWithMultipleTriggers do
        use SquidMesh.Workflow

        workflow do
          trigger :manual_digest do
            manual()

            payload do
              field(:chat_id, :integer)
            end
          end

          trigger :scheduled_digest do
            cron("0 9 * * *", timezone: "UTC")

            payload do
              field(:window_start_at, :string, default: {:today, :iso8601})
            end
          end

          step(:load_invoice, WorkflowWithMultipleTriggers.LoadInvoice)
          transition(:load_invoice, on: :ok, to: :complete)
        end
      end
      """)

    assert module.workflow_definition().triggers == [
             %{
               name: :manual_digest,
               type: :manual,
               config: %{},
               payload: [%{name: :chat_id, type: :integer, opts: []}]
             },
             %{
               name: :scheduled_digest,
               type: :cron,
               config: %{expression: "0 9 * * *", timezone: "UTC"},
               payload: [
                 %{name: :window_start_at, type: :string, opts: [default: {:today, :iso8601}]}
               ]
             }
           ]

    assert module.workflow_definition().payload == [
             %{name: :chat_id, type: :integer, opts: []}
           ]
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

  test "supports declarative built-in steps" do
    module =
      compile_module("""
      defmodule WorkflowWithBuiltInSteps do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:wait_for_settlement, :wait, duration: 250)
          step(:log_delivery, :log, message: "delivery completed", level: :info)

          transition(:wait_for_settlement, on: :ok, to: :log_delivery)
          transition(:log_delivery, on: :ok, to: :complete)
        end
      end
      """)

    assert module.workflow_definition().steps == [
             %{name: :wait_for_settlement, module: :wait, opts: [duration: 250]},
             %{
               name: :log_delivery,
               module: :log,
               opts: [message: "delivery completed", level: :info]
             }
           ]
  end

  test "fails when a built-in wait step is missing duration" do
    assert_compile_error(
      """
      defmodule WorkflowWithInvalidWaitStep do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:wait_for_settlement, :wait)
        end
      end
      """,
      "built-in step :wait_for_settlement requires a positive :duration option"
    )
  end

  test "fails when a built-in log step is missing message" do
    assert_compile_error(
      """
      defmodule WorkflowWithInvalidLogStep do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:log_delivery, :log, level: :warning)
        end
      end
      """,
      "built-in step :log_delivery requires a non-empty :message option"
    )
  end

  test "fails when a payload default does not match the declared field type" do
    assert_compile_error(
      """
      defmodule WorkflowWithInvalidPayloadDefault do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()

            payload do
              field(:max_attempts, :integer, default: "five")
            end
          end

          step(:load_invoice, WorkflowWithInvalidPayloadDefault.LoadInvoice)
        end
      end
      """,
      "payload field :max_attempts defines an invalid default for type :integer"
    )
  end

  test "fails when a dynamic payload default does not match the declared field type" do
    assert_compile_error(
      """
      defmodule WorkflowWithInvalidDynamicPayloadDefault do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()

            payload do
              field(:prompt_date, :integer, default: {:today, :iso8601})
            end
          end

          step(:load_invoice, WorkflowWithInvalidDynamicPayloadDefault.LoadInvoice)
        end
      end
      """,
      "payload field :prompt_date defines an invalid default for type :integer"
    )
  end

  test "fails when a transition declares an unsupported outcome" do
    assert_compile_error(
      """
      defmodule WorkflowWithUnsupportedTransitionOutcome do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:load_invoice, WorkflowWithUnsupportedTransitionOutcome.LoadInvoice)
          transition(:load_invoice, on: :unexpected, to: :complete)
        end
      end
      """,
      "transition from :load_invoice defines unsupported outcome :unexpected"
    )
  end

  test "supports transitions declared on :error outcomes" do
    module =
      compile_module("""
      defmodule WorkflowWithErrorTransition do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:check_gateway, WorkflowWithErrorTransition.CheckGateway)
          step(:notify_operator, WorkflowWithErrorTransition.NotifyOperator)

          transition(:check_gateway, on: :error, to: :notify_operator)
          transition(:notify_operator, on: :ok, to: :complete)
        end
      end
      """)

    assert module.workflow_definition().transitions == [
             %{from: :check_gateway, on: :error, to: :notify_operator},
             %{from: :notify_operator, on: :ok, to: :complete}
           ]
  end

  test "supports first-class approval step declarations" do
    module =
      compile_module("""
      defmodule WorkflowWithApprovalStep do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          approval_step(:wait_for_review, output: :approval)
          step(:record_approval, WorkflowWithApprovalStep.RecordApproval)
          step(:record_rejection, WorkflowWithApprovalStep.RecordRejection)

          transition(:wait_for_review, on: :ok, to: :record_approval)
          transition(:wait_for_review, on: :error, to: :record_rejection)
          transition(:record_approval, on: :ok, to: :complete)
          transition(:record_rejection, on: :ok, to: :complete)
        end
      end
      """)

    assert module.workflow_definition().steps == [
             %{name: :wait_for_review, module: :approval, opts: [output: :approval]},
             %{name: :record_approval, module: Module.concat(module, RecordApproval), opts: []},
             %{name: :record_rejection, module: Module.concat(module, RecordRejection), opts: []}
           ]
  end

  test "rejects built-in :pause steps in dependency-based workflows" do
    assert_compile_error(
      """
      defmodule DependencyWorkflowWithPause do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:load_account, DependencyWorkflowWithPause.LoadAccount)
          step(:wait_for_approval, :pause, after: [:load_account])
        end
      end
      """,
      "dependency-based workflows cannot declare built-in :pause steps"
    )
  end

  test "rejects approval steps in dependency-based workflows" do
    assert_compile_error(
      """
      defmodule DependencyWorkflowWithApproval do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:load_account, DependencyWorkflowWithApproval.LoadAccount)
          approval_step(:wait_for_review, after: [:load_account])
        end
      end
      """,
      "dependency-based workflows cannot declare built-in :approval steps"
    )
  end

  test "requires approval steps to declare both :ok and :error transitions" do
    assert_compile_error(
      """
      defmodule WorkflowWithIncompleteApprovalRouting do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          approval_step(:wait_for_review)
          step(:record_approval, WorkflowWithIncompleteApprovalRouting.RecordApproval)

          transition(:wait_for_review, on: :ok, to: :record_approval)
          transition(:record_approval, on: :ok, to: :complete)
        end
      end
      """,
      "approval step :wait_for_review must define both :ok and :error transitions"
    )
  end

  test "fails when duplicate transitions are declared for the same outcome" do
    assert_compile_error(
      """
      defmodule WorkflowWithDuplicateTransitions do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()
          end

          step(:check_gateway, WorkflowWithDuplicateTransitions.CheckGateway)
          step(:notify_operator, WorkflowWithDuplicateTransitions.NotifyOperator)
          step(:record_failure, WorkflowWithDuplicateTransitions.RecordFailure)

          transition(:check_gateway, on: :error, to: :notify_operator)
          transition(:check_gateway, on: :error, to: :record_failure)
        end
      end
      """,
      "duplicate transition declared from :check_gateway on outcome :error"
    )
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
      step(:send_email, InvoiceReminder.SendEmail, retry: [max_attempts: 3])
      step(:record_delivery, InvoiceReminder.RecordDelivery)

      transition(:load_invoice, on: :ok, to: :send_email)
      transition(:send_email, on: :ok, to: :record_delivery)
      transition(:record_delivery, on: :ok, to: :complete)
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
end
