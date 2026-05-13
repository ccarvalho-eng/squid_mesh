defmodule SquidMesh.Workflow.Dsl do
  @moduledoc """
  Spark DSL wrapper for Squid Mesh workflow declarations.

  This module installs the Squid Mesh Spark extension used by `use
  SquidMesh.Workflow`. Keeping the wrapper small lets the public workflow module
  own compatibility macros while Spark owns the stable step specification.
  """

  use Spark.Dsl,
    default_extensions: [
      extensions: [SquidMesh.Workflow.SparkExtension]
    ]
end
