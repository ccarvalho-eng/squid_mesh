defmodule SquidMesh.Workflow.Validation do
  @moduledoc """
  Compile-time validation and normalization for workflow modules.

  This module keeps contract enforcement in one place so the DSL in
  `SquidMesh.Workflow` can remain compact and declarative.
  """

  @terminal_transitions [:complete]
  @supported_transition_outcomes [:ok]
  @allowed_trigger_types [:manual, :cron]
  @built_in_step_kinds [:wait, :log]
  @log_levels [:debug, :info, :warning, :error]

  @doc """
  Validates a compiled workflow definition and raises a compile error when the
  declaration is invalid.
  """
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

  @doc """
  Returns the single workflow entry step or raises when the workflow does not
  define exactly one entry step.
  """
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

  @doc """
  Converts trigger declarations into the normalized runtime trigger shape.
  """
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

  @doc """
  Returns the canonical workflow payload contract derived from the trigger set.
  """
  @spec workflow_payload!([map()]) :: [map()]
  def workflow_payload!([trigger]), do: trigger.payload
  def workflow_payload!(_other), do: []

  @doc """
  Derives workflow retry declarations from per-step retry configuration.
  """
  @spec derive_retries([map()]) :: [map()]
  def derive_retries(steps) do
    Enum.flat_map(steps, fn step ->
      case Keyword.get(step.opts, :retry) do
        nil ->
          []

        opts when is_list(opts) ->
          [%{step: step.name, opts: opts}]

        opts ->
          [%{step: step.name, opts: opts}]
      end
    end)
  end

  defp validation_errors(definition) do
    step_names = Enum.map(definition.steps, & &1.name)
    payload_fields = workflow_payload_fields(definition)

    []
    |> validate_triggers(definition.triggers)
    |> validate_payload_defaults(payload_fields)
    |> require_steps(step_names)
    |> validate_built_in_steps(definition.steps)
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

  defp validate_payload_defaults(errors, payload_fields) do
    Enum.reduce(payload_fields, errors, fn field, acc ->
      case Keyword.fetch(field.opts, :default) do
        {:ok, default} ->
          if valid_payload_default?(field.type, default) do
            acc
          else
            [
              "payload field #{inspect(field.name)} defines an invalid default for type #{inspect(field.type)}"
              | acc
            ]
          end

        :error ->
          acc
      end
    end)
  end

  defp require_steps(errors, []), do: ["at least one step is required" | errors]
  defp require_steps(errors, _step_names), do: errors

  defp validate_built_in_steps(errors, steps) do
    Enum.reduce(steps, errors, fn step, acc ->
      validate_built_in_step(acc, step)
    end)
  end

  defp validate_built_in_step(errors, %{module: kind} = step) when kind in @built_in_step_kinds do
    case kind do
      :wait -> validate_wait_step(errors, step)
      :log -> validate_log_step(errors, step)
    end
  end

  defp validate_built_in_step(errors, _step), do: errors

  defp validate_wait_step(errors, %{name: name, opts: opts}) do
    duration = Keyword.get(opts, :duration)

    if is_integer(duration) and duration > 0 do
      errors
    else
      ["built-in step #{inspect(name)} requires a positive :duration option" | errors]
    end
  end

  defp validate_log_step(errors, %{name: name, opts: opts}) do
    errors
    |> validate_log_message(name, opts)
    |> validate_log_level(name, opts)
  end

  defp validate_log_message(errors, name, opts) do
    case Keyword.get(opts, :message) do
      message when is_binary(message) and message != "" ->
        errors

      _other ->
        ["built-in step #{inspect(name)} requires a non-empty :message option" | errors]
    end
  end

  defp validate_log_level(errors, name, opts) do
    case Keyword.get(opts, :level, :info) do
      level when level in @log_levels ->
        errors

      _other ->
        ["built-in step #{inspect(name)} defines unsupported :level" | errors]
    end
  end

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
      |> validate_transition_outcome(transition)
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

  defp validate_transition_outcome(errors, %{from: from, on: outcome}) do
    if outcome in @supported_transition_outcomes do
      errors
    else
      [
        "transition from #{inspect(from)} defines unsupported outcome #{inspect(outcome)}"
        | errors
      ]
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
    if is_list(opts) do
      max_attempts = Keyword.get(opts, :max_attempts)

      if is_integer(max_attempts) and max_attempts > 0 do
        validate_retry_backoff(errors, step, opts)
      else
        ["retry for #{inspect(step)} must define a positive :max_attempts" | errors]
      end
    else
      ["retry for #{inspect(step)} must define a positive :max_attempts" | errors]
    end
  end

  defp validate_retry_backoff(errors, step, opts) do
    case Keyword.get(opts, :backoff) do
      nil ->
        errors

      backoff when is_list(backoff) ->
        if valid_retry_backoff?(backoff) do
          errors
        else
          ["retry for #{inspect(step)} defines an invalid :backoff option" | errors]
        end

      _other ->
        ["retry for #{inspect(step)} defines an invalid :backoff option" | errors]
    end
  end

  defp valid_retry_backoff?(backoff) do
    case Keyword.get(backoff, :type) do
      :exponential ->
        min_delay = Keyword.get(backoff, :min)
        max_delay = Keyword.get(backoff, :max)

        is_integer(min_delay) and min_delay > 0 and
          is_integer(max_delay) and max_delay >= min_delay

      _other ->
        false
    end
  end

  defp valid_payload_default?(:string, {:today, :iso8601}), do: true
  defp valid_payload_default?(type, default), do: input_matches_type?(default, type)

  defp workflow_payload_fields(%{payload: payload}) when is_list(payload), do: payload

  defp workflow_payload_fields(%{triggers: [trigger]}) when is_map(trigger) do
    Map.get(trigger, :payload, [])
  end

  defp workflow_payload_fields(_definition), do: []

  defp entry_steps(definition) do
    transition_targets =
      definition.transitions
      |> Enum.map(& &1.to)
      |> MapSet.new()

    definition.steps
    |> Enum.map(& &1.name)
    |> Enum.reject(&MapSet.member?(transition_targets, &1))
  end

  defp input_matches_type?(value, :string), do: is_binary(value)
  defp input_matches_type?(value, :integer), do: is_integer(value)
  defp input_matches_type?(value, :float), do: is_float(value)
  defp input_matches_type?(value, :boolean), do: is_boolean(value)
  defp input_matches_type?(value, :map), do: is_map(value)
  defp input_matches_type?(value, :list), do: is_list(value)
  defp input_matches_type?(value, :atom), do: is_atom(value)
  defp input_matches_type?(_value, _unknown_type), do: true
end
