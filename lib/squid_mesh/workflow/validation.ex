defmodule SquidMesh.Workflow.Validation do
  @moduledoc false

  @terminal_transitions [:complete]

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

  defp validation_errors(definition) do
    step_names = Enum.map(definition.steps, & &1.name)

    []
    |> require_steps(step_names)
    |> validate_unique_step_names(step_names)
    |> validate_transitions(definition.transitions, step_names)
    |> validate_retries(definition.retries, step_names)
  end

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
end
