defmodule SquidMesh.Workflow.Spec do
  @moduledoc """
  Serializable, normalized workflow specification used to rebuild planner state.

  The public workflow DSL compiles to the runtime definition used by durable
  execution. This struct captures the same workflow shape as plain data so
  planner state can be reconstructed without exposing Runic structs as public
  API.
  """

  alias SquidMesh.Workflow.Definition

  @type t :: %__MODULE__{
          workflow: module(),
          triggers: [Definition.trigger()],
          payload: [Definition.payload_field()],
          steps: [Definition.step()],
          transitions: [Definition.transition()],
          retries: [Definition.retry()],
          entry_steps: [atom()],
          initial_step: atom(),
          entry_step: atom() | nil
        }

  defstruct [
    :workflow,
    triggers: [],
    payload: [],
    steps: [],
    transitions: [],
    retries: [],
    entry_steps: [],
    initial_step: nil,
    entry_step: nil
  ]

  @doc false
  @spec from_definition(module(), Definition.t()) :: t()
  def from_definition(workflow, definition) when is_atom(workflow) and is_map(definition) do
    %__MODULE__{
      workflow: workflow,
      triggers: definition.triggers,
      payload: definition.payload,
      steps: definition.steps,
      transitions: definition.transitions,
      retries: definition.retries,
      entry_steps: definition.entry_steps,
      initial_step: definition.initial_step,
      entry_step: definition.entry_step
    }
  end
end
