defmodule SquidMesh.Workflow do
  @moduledoc """
  Declarative workflow contract for Squid Mesh workflow modules.

  ## Example

      defmodule Billing.InvoiceReminder do
        use SquidMesh.Workflow

        workflow do
          trigger :manual do
            manual()

            payload do
              field :account_id, :string
              field :invoice_id, :string
            end
          end

          step :load_invoice, Billing.Steps.LoadInvoice
          step :send_email, Billing.Steps.SendReminderEmail

          transition :load_invoice, on: :ok, to: :send_email
          retry :send_email, max_attempts: 3
        end
      end

  The contract defined here captures workflow structure. Validation and runtime
  execution behavior are added in subsequent slices.
  """

  @contract %{
    required: [:trigger, :step],
    optional: [:transition, :retry]
  }

  alias SquidMesh.Workflow.Validation

  defmacro __using__(_opts) do
    quote do
      import SquidMesh.Workflow

      Module.register_attribute(__MODULE__, :squid_mesh_triggers, accumulate: true)
      Module.register_attribute(__MODULE__, :squid_mesh_steps, accumulate: true)
      Module.register_attribute(__MODULE__, :squid_mesh_transitions, accumulate: true)
      Module.register_attribute(__MODULE__, :squid_mesh_retries, accumulate: true)
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

  defmacro workflow(do: block), do: block

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

  defmacro manual do
    quote do
      SquidMesh.Workflow.__push_current_trigger_definition__(__MODULE__, %{
        type: :manual,
        config: %{}
      })
    end
  end

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

  defmacro payload(do: block) do
    quote bind_quoted: [block: Macro.escape(block)] do
      Module.put_attribute(__MODULE__, :squid_mesh_current_field_target, :trigger_payload)
      Code.eval_quoted(block, [], __ENV__)
      Module.delete_attribute(__MODULE__, :squid_mesh_current_field_target)
    end
  end

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

  defmacro step(name, module, opts \\ []) do
    quote bind_quoted: [name: name, module: module, opts: opts] do
      @squid_mesh_steps %{name: name, module: module, opts: opts}
    end
  end

  defmacro transition(from, opts) do
    quote bind_quoted: [from: from, opts: opts] do
      @squid_mesh_transitions %{
        from: from,
        on: Keyword.fetch!(opts, :on),
        to: Keyword.fetch!(opts, :to)
      }
    end
  end

  defmacro retry(step, opts) do
    quote bind_quoted: [step: step, opts: opts] do
      @squid_mesh_retries %{step: step, opts: opts}
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

    retries =
      env.module
      |> Module.get_attribute(:squid_mesh_retries)
      |> Enum.reverse()

    definition = %{
      triggers: triggers,
      steps: steps,
      transitions: transitions,
      retries: retries
    }

    Validation.validate!(definition, env)

    triggers = Validation.normalize_triggers!(definition)
    payload = Validation.workflow_payload!(triggers)
    entry_step = Validation.entry_step!(definition, env)

    definition =
      definition
      |> Map.put(:triggers, triggers)
      |> Map.put(:payload, payload)
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
