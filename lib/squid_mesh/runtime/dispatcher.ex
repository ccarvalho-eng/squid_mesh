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
  @type dispatch_opts :: [schedule_in: pos_integer()]

  @spec dispatch_run(Config.t(), Run.t(), dispatch_opts()) ::
          {:ok, Oban.Job.t()} | {:error, dispatch_error()}
  def dispatch_run(%Config{} = config, %Run{id: run_id}, opts \\ []) when is_binary(run_id) do
    schedule_in = Keyword.get(opts, :schedule_in)

    job_opts =
      [queue: config.execution_queue]
      |> maybe_put_schedule_in(schedule_in)

    %{run_id: run_id}
    |> StepWorker.new(job_opts)
    |> then(&Oban.insert(config.execution_name, &1))
  end

  defp maybe_put_schedule_in(opts, schedule_in)
       when is_integer(schedule_in) and schedule_in > 0 do
    Keyword.put(opts, :schedule_in, schedule_in)
  end

  defp maybe_put_schedule_in(opts, _schedule_in), do: opts
end
