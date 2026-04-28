defmodule MinimalHostApp.WorkflowRuns do
  @moduledoc """
  Application-facing boundary for workflow operations in the example host app.

  A real Phoenix or OTP application would call Squid Mesh from a context or
  service like this one rather than directly from controllers or jobs.
  """

  @type payment_recovery_attrs :: %{
          required(:account_id) => String.t(),
          required(:invoice_id) => String.t(),
          required(:attempt_id) => String.t()
        }

  @spec start_payment_recovery(payment_recovery_attrs()) ::
          {:ok, SquidMesh.Run.t()} | {:error, term()}
  def start_payment_recovery(attrs) when is_map(attrs) do
    SquidMesh.start_run(MinimalHostApp.Workflows.PaymentRecovery, :payment_recovery, attrs)
  end

  @spec inspect_payment_recovery(Ecto.UUID.t()) :: {:ok, SquidMesh.Run.t()} | {:error, term()}
  def inspect_payment_recovery(run_id) do
    SquidMesh.inspect_run(run_id)
  end
end
