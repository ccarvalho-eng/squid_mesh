defmodule SquidMesh.Step.Action do
  @moduledoc false

  use Jido.Action,
    name: "squid_mesh_native_step",
    description: "Internal adapter for native Squid Mesh steps"

  alias SquidMesh.Step
  alias SquidMesh.Step.Context

  @impl true
  def run(%{step: step, input: input}, context) when is_atom(step) and is_map(input) do
    with {:ok, input} <- Step.validate_input(step, input),
         {:ok, result} <- run_native_step(step, input, Context.from_map(context)),
         {:ok, output, opts} <- Step.normalize_result(result),
         {:ok, output} <- Step.validate_output(step, output) do
      {:ok, output, opts}
    end
  end

  def run(_params, _context) do
    {:error,
     %{
       message: "native step adapter received invalid params",
       retryable?: false
     }}
  end

  defp run_native_step(step, input, context) do
    {:ok, step.run(input, context)}
  rescue
    exception ->
      {:error,
       %{
         message: Exception.message(exception),
         exception: inspect(exception.__struct__),
         retryable?: false
       }}
  end
end
