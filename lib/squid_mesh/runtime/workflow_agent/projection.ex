defmodule SquidMesh.Runtime.WorkflowAgent.Projection do
  @moduledoc """
  Rebuildable workflow-agent projection over one run-thread journal.

  Dispatch completion is not treated as workflow progress here. A runnable is
  applied only after the run thread records `:runnable_applied`, preserving the
  durable ordering between dispatch results and workflow state transitions.
  """

  alias SquidMesh.Runtime.DispatchProtocol.Entry

  @type anomaly :: %{
          required(:reason) => atom(),
          required(:entry_type) => atom(),
          optional(:runnable_key) => String.t(),
          optional(:run_id) => String.t()
        }

  @type t :: %__MODULE__{
          run_id: String.t() | nil,
          workflow: String.t() | nil,
          status: atom(),
          planned_runnables: %{optional(String.t()) => map()},
          applied_runnable_keys: MapSet.t(String.t()),
          terminal_status: atom() | nil,
          anomalies: [anomaly()]
        }

  defstruct run_id: nil,
            workflow: nil,
            status: :new,
            planned_runnables: %{},
            applied_runnable_keys: MapSet.new(),
            terminal_status: nil,
            anomalies: []

  @spec rebuild([Entry.t()]) :: t()
  def rebuild(entries) when is_list(entries) do
    replay(%__MODULE__{}, entries)
  end

  @spec replay(t(), [Entry.t()]) :: t()
  def replay(%__MODULE__{} = projection, entries) when is_list(entries) do
    Enum.reduce(entries, projection, &apply_entry/2)
  end

  @spec status(t()) :: atom()
  def status(%__MODULE__{status: status}), do: status

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{terminal_status: nil}), do: false
  def terminal?(%__MODULE__{}), do: true

  @spec planned_runnable_keys(t()) :: [String.t()]
  def planned_runnable_keys(%__MODULE__{planned_runnables: planned_runnables}) do
    planned_runnables
    |> Map.keys()
    |> Enum.sort()
  end

  @spec planned_runnable_key?(t(), String.t()) :: boolean()
  def planned_runnable_key?(%__MODULE__{planned_runnables: planned_runnables}, runnable_key)
      when is_binary(runnable_key) do
    Map.has_key?(planned_runnables, runnable_key)
  end

  @spec applied_runnable_keys(t()) :: MapSet.t(String.t())
  def applied_runnable_keys(%__MODULE__{applied_runnable_keys: applied_runnable_keys}) do
    applied_runnable_keys
  end

  @spec anomalies(t()) :: [anomaly()]
  def anomalies(%__MODULE__{anomalies: anomalies}), do: Enum.reverse(anomalies)

  defp apply_entry(%Entry{type: :run_started, data: data}, %__MODULE__{} = projection) do
    projection
    |> Map.put(:run_id, data.run_id)
    |> Map.put(:workflow, data.workflow)
    |> refresh_status()
  end

  defp apply_entry(%Entry{type: :runnables_planned, data: data}, %__MODULE__{} = projection) do
    planned_runnables =
      data.runnables
      |> Enum.reduce(projection.planned_runnables, fn runnable, acc ->
        case runnable_key(runnable) do
          key when is_binary(key) -> Map.put_new(acc, key, normalize_runnable(runnable))
          _missing_key -> acc
        end
      end)

    projection
    |> Map.put(:planned_runnables, planned_runnables)
    |> Map.put(:run_id, projection.run_id || data.run_id)
    |> refresh_status()
  end

  defp apply_entry(
         %Entry{type: :runnable_applied, data: data} = entry,
         %__MODULE__{} = projection
       ) do
    if Map.has_key?(projection.planned_runnables, data.runnable_key) do
      projection
      |> Map.put(
        :applied_runnable_keys,
        MapSet.put(projection.applied_runnable_keys, data.runnable_key)
      )
      |> refresh_status()
    else
      add_anomaly(projection, entry, :unknown_runnable_intent)
    end
  end

  defp apply_entry(%Entry{type: :run_terminal, data: data}, %__MODULE__{} = projection) do
    %__MODULE__{
      projection
      | run_id: projection.run_id || data.run_id,
        status: data.status,
        terminal_status: data.status
    }
  end

  defp apply_entry(%Entry{}, %__MODULE__{} = projection), do: projection

  defp refresh_status(%__MODULE__{terminal_status: terminal_status} = projection)
       when not is_nil(terminal_status) do
    %__MODULE__{projection | status: terminal_status}
  end

  defp refresh_status(%__MODULE__{planned_runnables: planned_runnables} = projection)
       when map_size(planned_runnables) == 0 do
    %__MODULE__{projection | status: :started}
  end

  defp refresh_status(%__MODULE__{} = projection) do
    planned_keys = projection.planned_runnables |> Map.keys() |> MapSet.new()

    if MapSet.subset?(planned_keys, projection.applied_runnable_keys) do
      %__MODULE__{projection | status: :idle}
    else
      %__MODULE__{projection | status: :running}
    end
  end

  defp runnable_key(runnable) when is_map(runnable) do
    Map.get(runnable, :runnable_key) || Map.get(runnable, "runnable_key") ||
      Map.get(runnable, :key) || Map.get(runnable, "key")
  end

  defp runnable_key(_runnable), do: nil

  defp normalize_runnable(runnable) when is_map(runnable), do: Map.new(runnable)

  defp add_anomaly(%__MODULE__{} = projection, %Entry{} = entry, reason) do
    anomaly =
      %{
        reason: reason,
        entry_type: entry.type
      }
      |> maybe_put_run_id(Map.get(entry.data, :run_id))
      |> maybe_put_runnable_key(Map.get(entry.data, :runnable_key))

    %__MODULE__{projection | anomalies: [anomaly | projection.anomalies]}
  end

  defp maybe_put_run_id(anomaly, nil), do: anomaly
  defp maybe_put_run_id(anomaly, run_id), do: Map.put(anomaly, :run_id, run_id)

  defp maybe_put_runnable_key(anomaly, nil), do: anomaly

  defp maybe_put_runnable_key(anomaly, runnable_key) do
    Map.put(anomaly, :runnable_key, runnable_key)
  end
end
