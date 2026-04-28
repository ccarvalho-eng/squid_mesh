defmodule MinimalHostApp.Smoke do
  @moduledoc """
  Repeatable smoke-test entrypoint for the example host app.
  """

  alias MinimalHostApp.WorkflowRuns

  @spec run!() :: SquidMesh.Run.t()
  def run! do
    ensure_repo_started()

    attrs = %{
      account_id: "acct_demo",
      invoice_id: "inv_demo",
      attempt_id: "attempt_demo"
    }

    with {:ok, run} <- WorkflowRuns.start_payment_recovery(attrs),
         {:ok, inspected_run} <- WorkflowRuns.inspect_payment_recovery(run.id) do
      IO.puts("started run #{run.id} for #{inspect(run.workflow)}")

      unless inspected_run.id == run.id and inspected_run.current_step == :load_invoice do
        raise "unexpected smoke result"
      end

      inspected_run
    else
      {:error, reason} ->
        raise "smoke test failed: #{inspect(reason)}"
    end
  end

  @spec ensure_repo_started() :: :ok
  defp ensure_repo_started do
    repo = SquidMesh.config!().repo

    if repo == MinimalHostApp.TestSupport.FakeRepo and is_nil(Process.whereis(repo)) do
      {:ok, _pid} = repo.start_link()
    end

    :ok
  end
end
