defmodule SquidMesh.Runtime.ScheduleMetadata do
  @moduledoc """
  Normalizes scheduler metadata for cron-triggered workflow starts.

  Cron activation is intentionally host-owned: a host app decides when a
  declared cron trigger fires and queues a `SquidMesh.Executor.Payload.cron/3`
  payload. This module translates that delivery payload plus the compiled
  workflow trigger definition into the durable context stored on the new run.

  The persisted shape is reserved under `run.context.schedule` and is meant to
  answer two different questions:

  - what logical schedule window was intended by the scheduler
  - when Squid Mesh actually received and started processing the signal

  Keeping both timestamps matters because delayed delivery is normal in durable
  executors. Workflow steps should not infer their schedule window from current
  wall-clock time; they should read the intended window from the run context.

  The metadata is stored in run context rather than workflow payload so it does
  not participate in the workflow's business input contract. It also means the
  metadata survives reload, inspection, explanation, and replay without adding a
  database column for one trigger kind.
  """

  alias SquidMesh.Workflow.Definition, as: WorkflowDefinition

  @type t :: %{
          required(:trigger_name) => String.t(),
          required(:cron_expression) => String.t(),
          required(:timezone) => String.t(),
          required(:received_at) => String.t(),
          optional(:signal_id) => String.t(),
          optional(:intended_window) => map()
        }

  @doc """
  Builds the durable run context for one cron activation.

  The trigger definition contributes stable declarative data such as the trigger
  name, cron expression, and timezone. The executor payload contributes
  scheduler-delivery data such as `signal_id` and `intended_window`. If the
  scheduler omits `signal_id`, Squid Mesh derives one from the trigger and
  intended window when both window bounds are present. The runtime adds
  `received_at` at activation delivery time, so operators can compare scheduler
  intent against actual processing. Any `received_at` value in the payload is
  ignored because this timestamp belongs to the runner boundary.
  """
  @spec cron_context(WorkflowDefinition.trigger(), map()) :: %{schedule: t()}
  def cron_context(%{name: trigger_name, type: :cron, config: config}, payload)
      when is_map(config) and is_map(payload) do
    trigger_name = WorkflowDefinition.serialize_trigger(trigger_name)
    intended_window = intended_window(payload)

    %{
      schedule:
        %{
          trigger_name: trigger_name,
          cron_expression: Map.fetch!(config, :expression),
          timezone: Map.fetch!(config, :timezone),
          received_at: received_at()
        }
        |> maybe_put(:signal_id, signal_id(trigger_name, intended_window, payload))
        |> maybe_put(:intended_window, intended_window)
    }
  end

  defp signal_id(trigger_name, intended_window, payload) do
    case payload_value(payload, "signal_id") do
      signal_id when is_binary(signal_id) and signal_id != "" -> signal_id
      _other -> derived_signal_id(trigger_name, intended_window)
    end
  end

  defp derived_signal_id(trigger_name, %{start_at: start_at, end_at: end_at})
       when is_binary(trigger_name) and is_binary(start_at) and is_binary(end_at) do
    signal_parts = stable_signal_parts([trigger_name, start_at, end_at])
    digest = :crypto.hash(:sha256, signal_parts)

    "sha256:" <> Base.url_encode64(digest, padding: false)
  end

  defp derived_signal_id(_trigger_name, _intended_window), do: nil

  defp stable_signal_parts(parts) do
    parts
    |> Enum.map(fn part -> [Integer.to_string(byte_size(part)), ":", part] end)
    |> Enum.intersperse("|")
    |> IO.iodata_to_binary()
  end

  defp intended_window(payload) do
    case payload_value(payload, "intended_window") do
      %{} = window ->
        normalize_intended_window(window)

      _other ->
        nil
    end
  end

  defp normalize_intended_window(window) do
    %{}
    |> maybe_put(:start_at, window_value(window, :start_at))
    |> maybe_put(:end_at, window_value(window, :end_at))
    |> case do
      empty when map_size(empty) == 0 -> nil
      intended_window -> intended_window
    end
  end

  defp window_value(window, key) when is_atom(key) do
    value_with_fallback(window, Atom.to_string(key), key)
  end

  defp received_at do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp payload_value(payload, "signal_id"),
    do: value_with_fallback(payload, "signal_id", :signal_id)

  defp payload_value(payload, "intended_window") do
    value_with_fallback(payload, "intended_window", :intended_window)
  end

  defp value_with_fallback(map, preferred_key, fallback_key) do
    case Map.fetch(map, preferred_key) do
      {:ok, value} -> value
      :error -> Map.get(map, fallback_key)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
