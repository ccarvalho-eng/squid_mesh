defmodule SquidMesh.Workflow.Info do
  @moduledoc """
  Read helpers for compiled Squid Mesh workflow Spark metadata.

  The runtime still exposes `workflow_definition/0` for durable execution, while
  this module gives tests and tooling direct access to the Spark step entities
  produced by the workflow DSL.
  """

  @spec steps(module()) :: [SquidMesh.Workflow.StepSpec.t()]
  def steps(workflow) when is_atom(workflow) do
    workflow
    |> Spark.Dsl.Extension.get_entities([:workflow])
    |> Enum.map(&resolve_step_metadata/1)
  end

  defp resolve_step_metadata(%SquidMesh.Workflow.StepSpec{module: module} = step) do
    case SquidMesh.Step.metadata(module) do
      %{} = metadata -> %{step | metadata: metadata}
      nil -> step
    end
  end
end
