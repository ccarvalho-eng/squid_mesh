defmodule SquidMesh.Workflow.StepSpec do
  @moduledoc false

  defstruct [:name, :module, :__identifier__, __spark_metadata__: nil, opts: [], metadata: %{}]

  @type t :: %__MODULE__{
          name: atom(),
          module: module() | atom(),
          __identifier__: term(),
          opts: keyword(),
          metadata: map(),
          __spark_metadata__: term()
        }
end
