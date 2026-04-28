defmodule MinimalHostApp.WorkflowRuns do
  @moduledoc """
  Application-facing boundary for workflow operations in the example host app.

  A real Phoenix or OTP application would call Squid Mesh from a context or
  service like this one rather than directly from controllers or jobs.
  """

  @type payment_recovery_attrs :: %{
          required(:account_id) => String.t(),
          required(:invoice_id) => String.t(),
          required(:attempt_id) => String.t(),
          required(:gateway_url) => String.t()
        }

  @type cancellable_wait_attrs :: %{
          required(:account_id) => String.t()
        }

  @type retry_verification_attrs :: %{
          required(:attempt_id) => String.t()
        }

  @spec start_payment_recovery(payment_recovery_attrs()) ::
          {:ok, SquidMesh.Run.t()} | {:error, term()}
  def start_payment_recovery(attrs) when is_map(attrs) do
    SquidMesh.start_run(MinimalHostApp.Workflows.PaymentRecovery, :payment_recovery, attrs)
  end

  @spec start_cancellable_wait(cancellable_wait_attrs()) ::
          {:ok, SquidMesh.Run.t()} | {:error, term()}
  def start_cancellable_wait(attrs) when is_map(attrs) do
    SquidMesh.start_run(MinimalHostApp.Workflows.CancellableWait, attrs)
  end

  @spec start_retry_verification(retry_verification_attrs()) ::
          {:ok, SquidMesh.Run.t()} | {:error, term()}
  def start_retry_verification(attrs) when is_map(attrs) do
    SquidMesh.start_run(MinimalHostApp.Workflows.RetryVerification, :retry_verification, attrs)
  end

  @spec inspect_payment_recovery(Ecto.UUID.t()) :: {:ok, SquidMesh.Run.t()} | {:error, term()}
  def inspect_payment_recovery(run_id) do
    SquidMesh.inspect_run(run_id)
  end

  @spec inspect_run(Ecto.UUID.t(), keyword()) :: {:ok, SquidMesh.Run.t()} | {:error, term()}
  def inspect_run(run_id, opts \\ []) do
    SquidMesh.inspect_run(run_id, opts)
  end

  @spec cancel_run(Ecto.UUID.t()) :: {:ok, SquidMesh.Run.t()} | {:error, term()}
  def cancel_run(run_id) do
    SquidMesh.cancel_run(run_id)
  end

  @spec replay_run(Ecto.UUID.t()) :: {:ok, SquidMesh.Run.t()} | {:error, term()}
  def replay_run(run_id) do
    SquidMesh.replay_run(run_id)
  end

  @spec list_daily_digest_runs() :: {:ok, [SquidMesh.Run.t()]} | {:error, term()}
  def list_daily_digest_runs do
    SquidMesh.list_runs(workflow: MinimalHostApp.Workflows.DailyDigest)
  end
end
