defmodule SquidMesh.Workflow.Dsl do
  @moduledoc false

  use Spark.Dsl,
    default_extensions: [
      extensions: [SquidMesh.Workflow.SparkExtension]
    ]
end
