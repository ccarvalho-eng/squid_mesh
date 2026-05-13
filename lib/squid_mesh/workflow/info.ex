defmodule SquidMesh.Workflow.Info do
  @moduledoc """
  Read helpers for compiled Squid Mesh workflow Spark metadata.

  The runtime still exposes `workflow_definition/0` for durable execution, while
  this module gives tests and tooling direct access to the Spark step entities
  produced by the workflow DSL.
  """

  @spec steps(module()) :: [SquidMesh.Workflow.StepSpec.t()]
  def steps(workflow) when is_atom(workflow) do
    Spark.Dsl.Extension.get_entities(workflow, [:workflow])
  end
end
