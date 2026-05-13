defmodule SquidMesh.Executor.Payload do
  @moduledoc """
  Backend-neutral payloads that host executors can hand to their queue.
  """

  alias SquidMesh.Run
  alias SquidMesh.Workflow.Definition, as: WorkflowDefinition

  @type t :: %{
          required(String.t()) => String.t() | boolean()
        }

  @spec step(Run.t(), atom() | String.t()) :: t()
  def step(%Run{id: run_id}, step) do
    %{
      "kind" => "step",
      "run_id" => run_id,
      "step" => WorkflowDefinition.serialize_step(step)
    }
  end

  @spec compensation(Run.t()) :: t()
  def compensation(%Run{id: run_id}) do
    %{
      "kind" => "compensation",
      "run_id" => run_id
    }
  end

  @spec cron(module(), atom() | String.t()) :: t()
  def cron(workflow, trigger) when is_atom(workflow) do
    %{
      "kind" => "cron",
      "workflow" => WorkflowDefinition.serialize_workflow(workflow),
      "trigger" => WorkflowDefinition.serialize_trigger(trigger)
    }
  end
end
