defmodule SquidMesh.Workflow do
  @moduledoc """
  Declarative workflow contract for Squid Mesh workflow modules.

  ## Example

      defmodule Billing.InvoiceReminder do
        use SquidMesh.Workflow

        workflow do
          trigger :invoice_delivery do
            manual()

            payload do
              field :account_id, :string
              field :invoice_id, :string
            end
          end

          step :load_invoice, Billing.Steps.LoadInvoice
          step :send_email, Billing.Steps.SendReminderEmail, retry: [max_attempts: 3]

          transition :load_invoice, on: :ok, to: :send_email
        end
      end

  The contract defined here captures workflow structure. Validation and runtime
  execution behavior are added in subsequent slices.
  """

  @contract %{
    required: [:trigger, :step],
    optional: [:transition]
  }

  alias SquidMesh.Workflow.Validation

  defmacro __using__(_opts) do
    quote do
      import SquidMesh.Workflow

      Module.register_attribute(__MODULE__, :squid_mesh_triggers, accumulate: true)
      Module.register_attribute(__MODULE__, :squid_mesh_steps, accumulate: true)
      Module.register_attribute(__MODULE__, :squid_mesh_transitions, accumulate: true)
      Module.register_attribute(__MODULE__, :squid_mesh_current_field_target, persist: false)
      Module.register_attribute(__MODULE__, :squid_mesh_current_trigger_name, persist: false)

      Module.register_attribute(
        __MODULE__,
        :squid_mesh_current_trigger_definitions,
        persist: false
      )

      Module.register_attribute(
        __MODULE__,
        :squid_mesh_current_trigger_payload_fields,
        persist: false
      )

      @before_compile SquidMesh.Workflow
    end
  end

  @doc """
  Declares the workflow body.
  """
  defmacro workflow(do: block), do: block

  @doc """
  Declares a named workflow trigger.
  """
  defmacro trigger(name, do: block) do
    quote bind_quoted: [name: name, block: Macro.escape(block)] do
      Module.put_attribute(__MODULE__, :squid_mesh_current_trigger_name, name)
      Module.put_attribute(__MODULE__, :squid_mesh_current_trigger_definitions, [])
      Module.put_attribute(__MODULE__, :squid_mesh_current_trigger_payload_fields, [])

      Code.eval_quoted(block, [], __ENV__)

      trigger = %{
        name: Module.get_attribute(__MODULE__, :squid_mesh_current_trigger_name),
        definitions:
          __MODULE__
          |> Module.get_attribute(:squid_mesh_current_trigger_definitions)
          |> Enum.reverse(),
        payload:
          __MODULE__
          |> Module.get_attribute(:squid_mesh_current_trigger_payload_fields)
          |> Enum.reverse()
      }

      @squid_mesh_triggers trigger

      Module.delete_attribute(__MODULE__, :squid_mesh_current_trigger_name)
      Module.delete_attribute(__MODULE__, :squid_mesh_current_trigger_definitions)
      Module.delete_attribute(__MODULE__, :squid_mesh_current_trigger_payload_fields)
    end
  end

  @doc """
  Declares a manual trigger.
  """
  defmacro manual do
    quote do
      SquidMesh.Workflow.__push_current_trigger_definition__(__MODULE__, %{
        type: :manual,
        config: %{}
      })
    end
  end

  @doc """
  Declares a cron-based trigger.
  """
  defmacro cron(expression, opts \\ []) do
    quote bind_quoted: [expression: expression, opts: opts] do
      SquidMesh.Workflow.__push_current_trigger_definition__(__MODULE__, %{
        type: :cron,
        config: %{
          expression: expression,
          timezone: Keyword.get(opts, :timezone)
        }
      })
    end
  end

  @doc """
  Declares the payload contract for the current trigger.
  """
  defmacro payload(do: block) do
    quote bind_quoted: [block: Macro.escape(block)] do
      Module.put_attribute(__MODULE__, :squid_mesh_current_field_target, :trigger_payload)
      Code.eval_quoted(block, [], __ENV__)
      Module.delete_attribute(__MODULE__, :squid_mesh_current_field_target)
    end
  end

  @doc """
  Declares one payload field inside a trigger payload block.
  """
  defmacro field(name, type, opts \\ []) do
    quote bind_quoted: [name: name, type: type, opts: opts] do
      field = %{name: name, type: type, opts: opts}

      case Module.get_attribute(__MODULE__, :squid_mesh_current_field_target) do
        :trigger_payload ->
          SquidMesh.Workflow.__push_current_trigger_payload_field__(__MODULE__, field)

        _other ->
          raise CompileError,
            file: __ENV__.file,
            line: __ENV__.line,
            description: "field/3 must be declared inside a trigger payload block"
      end
    end
  end

  @doc """
  Declares one workflow step.
  """
  defmacro step(name, module, opts \\ []) do
    quote bind_quoted: [name: name, module: module, opts: opts] do
      @squid_mesh_steps %{name: name, module: module, opts: opts}
    end
  end

  @doc """
  Declares a first-class approval step for manual review decisions.
  """
  defmacro approval_step(name, opts \\ []) do
    quote bind_quoted: [name: name, opts: opts] do
      @squid_mesh_steps %{name: name, module: :approval, opts: opts}
    end
  end

  @doc """
  Declares a manual review step as an alias of `approval_step/2`.
  """
  defmacro manual_review_step(name, opts \\ []) do
    quote bind_quoted: [name: name, opts: opts] do
      @squid_mesh_steps %{name: name, module: :approval, opts: opts}
    end
  end

  @doc """
  Declares a transition from one step outcome to the next step.
  """
  defmacro transition(from, opts) do
    quote bind_quoted: [from: from, opts: opts] do
      transition = %{
        from: from,
        on: Keyword.fetch!(opts, :on),
        to: Keyword.fetch!(opts, :to)
      }

      transition =
        case Keyword.fetch(opts, :recovery) do
          {:ok, recovery} -> Map.put(transition, :recovery, recovery)
          :error -> transition
        end

      @squid_mesh_transitions transition
    end
  end

  defmacro __before_compile__(env) do
    triggers =
      env.module
      |> Module.get_attribute(:squid_mesh_triggers)
      |> Enum.reverse()

    steps =
      env.module
      |> Module.get_attribute(:squid_mesh_steps)
      |> Enum.reverse()

    transitions =
      env.module
      |> Module.get_attribute(:squid_mesh_transitions)
      |> Enum.reverse()

    definition = %{
      triggers: triggers,
      steps: steps,
      transitions: transitions,
      retries: Validation.derive_retries(steps)
    }

    Validation.validate!(definition, env)

    triggers = Validation.normalize_triggers!(definition)
    payload = Validation.workflow_payload!(triggers)
    entry_steps = Validation.entry_steps!(definition, env)
    initial_step = Validation.initial_step!(definition, env)
    entry_step = Validation.entry_step!(definition, env)

    definition =
      definition
      |> Map.put(:triggers, triggers)
      |> Map.put(:payload, payload)
      |> Map.put(:entry_steps, entry_steps)
      |> Map.put(:initial_step, initial_step)
      |> Map.put(:entry_step, entry_step)

    quote do
      @doc false
      def workflow_definition, do: unquote(Macro.escape(definition))

      @doc false
      def __workflow__(:definition), do: unquote(Macro.escape(definition))

      @doc false
      def __workflow__(:contract), do: unquote(Macro.escape(@contract))

      @doc false
      def __workflow__(:payload), do: unquote(Macro.escape(definition.payload))

      @doc false
      def __workflow__(:triggers), do: unquote(Macro.escape(definition.triggers))

      @doc false
      def __workflow__(:steps), do: unquote(Macro.escape(definition.steps))

      @doc false
      def __workflow__(:transitions), do: unquote(Macro.escape(definition.transitions))

      @doc false
      def __workflow__(:retries), do: unquote(Macro.escape(definition.retries))

      @doc false
      def __workflow__(:entry_step), do: unquote(Macro.escape(definition.entry_step))

      @doc false
      def __workflow__(:entry_steps), do: unquote(Macro.escape(definition.entry_steps))

      @doc false
      def __workflow__(:initial_step), do: unquote(Macro.escape(definition.initial_step))
    end
  end

  @doc false
  @spec __push_current_trigger_definition__(module(), map()) :: :ok
  def __push_current_trigger_definition__(module, definition)
      when is_atom(module) and is_map(definition) do
    definitions = Module.get_attribute(module, :squid_mesh_current_trigger_definitions) || []

    Module.put_attribute(module, :squid_mesh_current_trigger_definitions, [
      definition | definitions
    ])

    :ok
  end

  @doc false
  @spec __push_current_trigger_payload_field__(module(), map()) :: :ok
  def __push_current_trigger_payload_field__(module, field)
      when is_atom(module) and is_map(field) do
    fields = Module.get_attribute(module, :squid_mesh_current_trigger_payload_fields) || []
    Module.put_attribute(module, :squid_mesh_current_trigger_payload_fields, [field | fields])
    :ok
  end
end
