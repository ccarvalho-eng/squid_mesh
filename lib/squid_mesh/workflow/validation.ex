defmodule SquidMesh.Workflow.Validation do
  @moduledoc false

  @terminal_transitions [:complete]
  @allowed_trigger_types [:manual, :cron]

  @spec validate!(map(), Macro.Env.t()) :: :ok
  def validate!(definition, env) do
    case validation_errors(definition) do
      [] ->
        :ok

      errors ->
        description =
          ["workflow validation failed:" | Enum.map(errors, &"- #{&1}")]
          |> Enum.join("\n")

        raise CompileError,
          file: env.file,
          line: env.line,
          description: description
    end
  end

  @spec entry_step!(map(), Macro.Env.t()) :: atom()
  def entry_step!(definition, env) do
    case entry_steps(definition) do
      [entry_step] ->
        entry_step

      _other_steps ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "workflow validation failed:\n- workflow must define exactly one entry step"
    end
  end

  @spec normalize_triggers!(map()) :: [map()]
  def normalize_triggers!(definition) do
    Enum.map(definition.triggers, fn trigger ->
      definition_entry = List.first(trigger.definitions)

      %{
        name: trigger.name,
        type: definition_entry.type,
        config: definition_entry.config,
        payload: trigger.payload
      }
    end)
  end

  @spec workflow_payload!([map()]) :: [map()]
  def workflow_payload!([trigger]), do: trigger.payload
  def workflow_payload!(_other), do: []

  defp validation_errors(definition) do
    step_names = Enum.map(definition.steps, & &1.name)

    []
    |> validate_triggers(definition.triggers)
    |> require_steps(step_names)
    |> validate_unique_step_names(step_names)
    |> validate_transitions(definition.transitions, step_names)
    |> validate_retries(definition.retries, step_names)
  end

  defp validate_triggers(errors, triggers) do
    errors
    |> validate_trigger_count(triggers)
    |> validate_trigger_definitions(triggers)
  end

  defp validate_trigger_count(errors, [_trigger]), do: errors
  defp validate_trigger_count(errors, _other), do: ["exactly one trigger is required" | errors]

  defp validate_trigger_definitions(errors, triggers) do
    Enum.reduce(triggers, errors, fn trigger, acc ->
      acc
      |> validate_trigger_type_count(trigger)
      |> validate_trigger_type_allowed(trigger)
      |> validate_trigger_config(trigger)
    end)
  end

  defp validate_trigger_type_count(errors, %{definitions: [_single_definition]}) do
    errors
  end

  defp validate_trigger_type_count(errors, %{name: name}) do
    ["trigger #{inspect(name)} must define exactly one type" | errors]
  end

  defp validate_trigger_type_allowed(errors, %{definitions: [%{type: type}]})
       when type in @allowed_trigger_types do
    errors
  end

  defp validate_trigger_type_allowed(errors, %{name: name, definitions: [%{type: type}]}) do
    ["trigger #{inspect(name)} defines unsupported type #{inspect(type)}" | errors]
  end

  defp validate_trigger_type_allowed(errors, _trigger), do: errors

  defp validate_trigger_config(errors, %{definitions: [%{type: :manual}]}) do
    errors
  end

  defp validate_trigger_config(errors, %{
         name: name,
         definitions: [%{type: :cron, config: config}]
       }) do
    expression = Map.get(config, :expression)
    timezone = Map.get(config, :timezone)

    if is_binary(expression) and expression != "" and is_binary(timezone) and timezone != "" do
      errors
    else
      ["trigger #{inspect(name)} must define a cron expression and timezone" | errors]
    end
  end

  defp validate_trigger_config(errors, _trigger), do: errors

  defp require_steps(errors, []), do: ["at least one step is required" | errors]
  defp require_steps(errors, _step_names), do: errors

  defp validate_unique_step_names(errors, step_names) do
    duplicates =
      step_names
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map_join(", ", fn {name, _count} -> inspect(name) end)

    case duplicates do
      "" -> errors
      names -> ["duplicate step names: #{names}" | errors]
    end
  end

  defp validate_transitions(errors, transitions, step_names) do
    Enum.reduce(transitions, errors, fn transition, acc ->
      acc
      |> validate_transition_from(transition, step_names)
      |> validate_transition_to(transition, step_names)
    end)
  end

  defp validate_transition_from(errors, %{from: from}, step_names) do
    if from in step_names do
      errors
    else
      ["transition references unknown step: #{inspect(from)}" | errors]
    end
  end

  defp validate_transition_to(errors, %{to: to}, step_names) do
    if to in step_names or to in @terminal_transitions do
      errors
    else
      ["transition targets unknown step: #{inspect(to)}" | errors]
    end
  end

  defp validate_retries(errors, retries, step_names) do
    Enum.reduce(retries, errors, fn retry, acc ->
      acc
      |> validate_retry_step(retry, step_names)
      |> validate_retry_opts(retry)
    end)
  end

  defp validate_retry_step(errors, %{step: step}, step_names) do
    if step in step_names do
      errors
    else
      ["retry references unknown step: #{inspect(step)}" | errors]
    end
  end

  defp validate_retry_opts(errors, %{step: step, opts: opts}) do
    max_attempts = Keyword.get(opts, :max_attempts)

    if is_integer(max_attempts) and max_attempts > 0 do
      errors
    else
      ["retry for #{inspect(step)} must define a positive :max_attempts" | errors]
    end
  end

  defp entry_steps(definition) do
    transition_targets =
      definition.transitions
      |> Enum.map(& &1.to)
      |> MapSet.new()

    definition.steps
    |> Enum.map(& &1.name)
    |> Enum.reject(&MapSet.member?(transition_targets, &1))
  end
end
