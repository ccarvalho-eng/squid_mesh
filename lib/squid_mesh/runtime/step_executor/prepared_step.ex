defmodule SquidMesh.Runtime.StepExecutor.PreparedStep do
  @moduledoc false

  alias SquidMesh.Config
  alias SquidMesh.Run
  alias SquidMesh.Workflow.Definition, as: WorkflowDefinition

  @enforce_keys [:config, :definition, :run, :step_name, :step, :step_run, :input]
  defstruct [:config, :definition, :run, :step_name, :step, :step_run, :input]

  @type t :: %__MODULE__{
          config: Config.t(),
          definition: WorkflowDefinition.t(),
          run: Run.t(),
          step_name: atom(),
          step: WorkflowDefinition.step(),
          step_run: SquidMesh.Persistence.StepRun.t(),
          input: map()
        }
end
