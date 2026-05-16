defmodule SquidMesh.Runtime.ScheduleMetadata do
  @moduledoc false

  alias SquidMesh.Workflow.Definition, as: WorkflowDefinition

  @type t :: %{
          required(:trigger_name) => String.t(),
          required(:cron_expression) => String.t(),
          required(:timezone) => String.t(),
          required(:signal_id) => String.t(),
          required(:received_at) => String.t(),
          optional(:intended_window) => map()
        }

  @spec cron_context(WorkflowDefinition.trigger(), map()) :: %{schedule: t()}
  def cron_context(%{name: trigger_name, type: :cron, config: config}, payload)
      when is_map(config) and is_map(payload) do
    %{
      schedule:
        %{
          trigger_name: WorkflowDefinition.serialize_trigger(trigger_name),
          cron_expression: Map.fetch!(config, :expression),
          timezone: Map.fetch!(config, :timezone),
          signal_id: signal_id(payload),
          received_at: received_at()
        }
        |> maybe_put(:intended_window, intended_window(payload))
    }
  end

  defp signal_id(payload) do
    case payload_value(payload, "signal_id") do
      signal_id when is_binary(signal_id) and signal_id != "" -> signal_id
      _other -> Ecto.UUID.generate()
    end
  end

  defp intended_window(payload) do
    case payload_value(payload, "intended_window") do
      %{} = window ->
        window
        |> Map.new(fn {key, value} -> {normalize_window_key(key), value} end)
        |> Map.take([:start_at, :end_at])
        |> case do
          empty when map_size(empty) == 0 -> nil
          intended_window -> intended_window
        end

      _other ->
        nil
    end
  end

  defp received_at do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp payload_value(payload, "signal_id"),
    do: Map.get(payload, "signal_id", Map.get(payload, :signal_id))

  defp payload_value(payload, "intended_window") do
    Map.get(payload, "intended_window", Map.get(payload, :intended_window))
  end

  defp payload_value(payload, key) when is_binary(key) do
    Map.get(payload, key)
  end

  defp normalize_window_key(key) when is_atom(key), do: key

  defp normalize_window_key(key) when is_binary(key) do
    case key do
      "start_at" -> :start_at
      "end_at" -> :end_at
      other -> other
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
