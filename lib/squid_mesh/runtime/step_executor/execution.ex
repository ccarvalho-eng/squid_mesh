defmodule SquidMesh.Runtime.StepExecutor.Execution do
  @moduledoc """
  Executes a prepared workflow step without mutating durable run state.

  This phase is intentionally narrow: it runs built-in steps or Jido actions
  using a previously prepared input snapshot and returns an execution result for
  the apply phase to persist.
  """

  alias SquidMesh.Run
  alias SquidMesh.Runtime.StepExecutor.PreparedStep

  @spec execute(PreparedStep.t()) :: {:ok, map(), keyword()} | {:error, term()}
  def execute(%PreparedStep{
        step_name: _step_name,
        step: %{module: built_in_kind, opts: opts},
        input: input,
        run: run
      })
      when built_in_kind in [:wait, :log] do
    SquidMesh.Runtime.BuiltInStep.execute(built_in_kind, opts, input, run)
  end

  def execute(%PreparedStep{
        step_name: step_name,
        step: %{module: action},
        input: input,
        run: %Run{} = run
      }) do
    context = %{
      run_id: run.id,
      workflow: run.workflow,
      step: step_name,
      state: run.context || %{}
    }

    case Jido.Exec.run(action, input, context, max_retries: 0) do
      {:ok, output} when is_map(output) -> {:ok, output, []}
      {:ok, output, _extras} when is_map(output) -> {:ok, output, []}
      {:error, reason} -> {:error, reason}
    end
  end
end
