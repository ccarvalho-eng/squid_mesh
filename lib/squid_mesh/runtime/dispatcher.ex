defmodule SquidMesh.Runtime.Dispatcher do
  @moduledoc """
  Enqueues durable workflow step execution.

  The workflow contract stays declarative while this module bridges runtime
  intent into Oban-backed execution jobs.
  """

  alias SquidMesh.Config
  alias SquidMesh.Run
  alias SquidMesh.Workers.StepWorker

  @type dispatch_error :: Ecto.Changeset.t() | term()

  @spec dispatch_run(Config.t(), Run.t()) :: {:ok, Oban.Job.t()} | {:error, dispatch_error()}
  def dispatch_run(%Config{} = config, %Run{id: run_id}) when is_binary(run_id) do
    %{run_id: run_id}
    |> StepWorker.new(queue: config.execution_queue)
    |> then(&Oban.insert(config.execution_name, &1))
  end
end
