defmodule SquidMesh.Executor.Payload do
  @moduledoc """
  Backend-neutral payloads that host executors can hand to their queue.
  """

  alias SquidMesh.Run
  alias SquidMesh.Workflow.Definition, as: WorkflowDefinition

  @type t :: %{
          required(String.t()) => String.t() | boolean() | map()
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
  @spec cron(module(), atom() | String.t(), keyword()) :: t()
  def cron(workflow, trigger, opts \\ []) when is_atom(workflow) and is_list(opts) do
    %{
      "kind" => "cron",
      "workflow" => WorkflowDefinition.serialize_workflow(workflow),
      "trigger" => WorkflowDefinition.serialize_trigger(trigger)
    }
    |> maybe_put("signal_id", Keyword.get(opts, :signal_id))
    |> maybe_put("intended_window", Keyword.get(opts, :intended_window))
  end

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)
end
