defmodule SquidMesh.Workflow do
  @moduledoc """
  Declarative workflow contract for Squid Mesh workflow modules.

  ## Example

      defmodule Billing.InvoiceReminder do
        use SquidMesh.Workflow

        workflow do
          input do
            field :account_id, :string
            field :invoice_id, :string
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
    required: [:step],
    optional: [:input, :transition, :retry]
  }

  defmacro __using__(_opts) do
    quote do
      import SquidMesh.Workflow

      Module.register_attribute(__MODULE__, :squid_mesh_input_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :squid_mesh_steps, accumulate: true)
      Module.register_attribute(__MODULE__, :squid_mesh_transitions, accumulate: true)
      Module.register_attribute(__MODULE__, :squid_mesh_retries, accumulate: true)

      @before_compile SquidMesh.Workflow
    end
  end

  defmacro workflow(do: block), do: block

  defmacro input(do: block), do: block

  defmacro field(name, type, opts \\ []) do
    quote bind_quoted: [name: name, type: type, opts: opts] do
      @squid_mesh_input_fields %{name: name, type: type, opts: opts}
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
    input =
      env.module
      |> Module.get_attribute(:squid_mesh_input_fields)
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
      input: input,
      steps: steps,
      transitions: transitions,
      retries: retries
    }

    quote do
      @doc false
      def workflow_definition, do: unquote(Macro.escape(definition))

      @doc false
      def __workflow__(:definition), do: unquote(Macro.escape(definition))

      @doc false
      def __workflow__(:contract), do: unquote(Macro.escape(@contract))

      @doc false
      def __workflow__(:input), do: unquote(Macro.escape(definition.input))

      @doc false
      def __workflow__(:steps), do: unquote(Macro.escape(definition.steps))

      @doc false
      def __workflow__(:transitions), do: unquote(Macro.escape(definition.transitions))

      @doc false
      def __workflow__(:retries), do: unquote(Macro.escape(definition.retries))
    end
  end
end
