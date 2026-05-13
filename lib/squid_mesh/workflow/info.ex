defmodule SquidMesh.Workflow.Info do
  @moduledoc false

  @spec steps(module()) :: [SquidMesh.Workflow.StepSpec.t()]
  def steps(workflow) when is_atom(workflow) do
    Spark.Dsl.Extension.get_entities(workflow, [:workflow])
  end
end
