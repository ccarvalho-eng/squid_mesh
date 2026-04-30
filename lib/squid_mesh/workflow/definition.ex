defmodule SquidMesh.Workflow.Definition do
  @moduledoc """
  Runtime-facing representation of a compiled workflow definition.

  `SquidMesh.Workflow` builds the declarative DSL at compile time. This module
  loads the compiled definition and applies the runtime operations needed for
  run creation, payload resolution, and persistence serialization.
  """

  @type built_in_step_kind :: :wait | :log
  @type payload_field :: %{name: atom(), type: atom(), opts: keyword()}
  @type trigger_type :: :manual | :cron
  @type trigger :: %{
          name: atom(),
          type: trigger_type(),
          config: map(),
          payload: [payload_field()]
        }
  @type step :: %{name: atom(), module: module() | built_in_step_kind(), opts: keyword()}
  @type transition :: %{from: atom(), on: atom(), to: atom()}
  @type retry :: %{step: atom(), opts: keyword()}

  @type t :: %{
          triggers: [trigger()],
          payload: [payload_field()],
          steps: [step()],
          transitions: [transition()],
          retries: [retry()],
          entry_steps: [atom()],
          initial_step: atom(),
          entry_step: atom() | nil
        }

  @type load_error :: {:invalid_workflow, module() | String.t()}
  @type trigger_error :: {:invalid_trigger, atom() | String.t()}
  @type payload_error_details :: %{
          optional(:missing_fields) => [atom()],
          optional(:unknown_fields) => [atom() | String.t()],
          optional(:invalid_types) => %{optional(atom()) => atom()}
        }
  @type transition_target :: atom() | :complete

  @doc """
  Loads a compiled workflow definition from a workflow module.
  """
  @spec load(module()) :: {:ok, t()} | {:error, load_error()}
  def load(workflow) when is_atom(workflow) do
    case Code.ensure_loaded(workflow) do
      {:module, ^workflow} ->
        if function_exported?(workflow, :workflow_definition, 0) do
          {:ok, workflow.workflow_definition()}
        else
          {:error, {:invalid_workflow, workflow}}
        end

      {:error, _reason} ->
        {:error, {:invalid_workflow, workflow}}
    end
  end

  @doc """
  Loads a workflow definition from its persisted module name.
  """
  @spec load_serialized(String.t()) :: {:ok, module(), t()} | {:error, load_error()}
  def load_serialized(workflow_name) when is_binary(workflow_name) do
    with {:ok, workflow} <- deserialize_workflow_name(workflow_name),
         {:ok, definition} <- load(workflow) do
      {:ok, workflow, definition}
    else
      {:error, _reason} -> {:error, {:invalid_workflow, workflow_name}}
    end
  end

  @doc """
  Validates a payload map against the workflow payload contract.
  """
  @spec validate_payload(t(), map()) ::
          :ok | {:error, {:invalid_payload, payload_error_details()}}
  def validate_payload(definition, payload) when is_map(payload) do
    declared_fields = definition.payload
    declared_names = MapSet.new(Enum.map(declared_fields, & &1.name))
    provided_names = MapSet.new(Map.keys(payload))

    missing_fields =
      declared_fields
      |> Enum.filter(
        &(Keyword.get(&1.opts, :required, true) and not Map.has_key?(payload, &1.name))
      )
      |> Enum.map(& &1.name)

    unknown_fields =
      provided_names
      |> MapSet.to_list()
      |> Enum.reject(&MapSet.member?(declared_names, &1))
      |> Enum.sort_by(&to_string/1)

    invalid_types =
      declared_fields
      |> Enum.reduce(%{}, fn field, acc ->
        case Map.fetch(payload, field.name) do
          {:ok, value} ->
            if input_matches_type?(value, field.type) do
              acc
            else
              Map.put(acc, field.name, field.type)
            end

          :error ->
            acc
        end
      end)

    errors =
      %{}
      |> maybe_put(:missing_fields, missing_fields)
      |> maybe_put(:unknown_fields, unknown_fields)
      |> maybe_put(:invalid_types, invalid_types)

    case errors do
      %{} = empty when map_size(empty) == 0 -> :ok
      details -> {:error, {:invalid_payload, details}}
    end
  end

  @doc """
  Resolves payload defaults and validates the final payload for a new run.
  """
  @spec resolve_payload(t(), map()) ::
          {:ok, map()} | {:error, {:invalid_payload, payload_error_details()}}
  def resolve_payload(definition, payload) when is_map(payload) do
    resolved_payload =
      Enum.reduce(definition.payload, payload, fn field, acc ->
        case Map.has_key?(acc, field.name) do
          true ->
            acc

          false ->
            case Keyword.fetch(field.opts, :default) do
              {:ok, default} -> Map.put(acc, field.name, resolve_default!(default))
              :error -> acc
            end
        end
      end)

    case validate_payload(definition, resolved_payload) do
      :ok -> {:ok, resolved_payload}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns the workflow entry step.
  """
  @spec entry_step(t()) :: atom() | nil
  def entry_step(definition), do: definition.entry_step

  @doc """
  Returns the workflow entry steps in semantic execution order.
  """
  @spec entry_steps(t()) :: [atom()]
  def entry_steps(definition), do: definition.entry_steps

  @doc """
  Returns the first step scheduled when a run starts.
  """
  @spec initial_step(t()) :: atom()
  def initial_step(definition), do: definition.initial_step

  @doc """
  Returns the default trigger for the workflow definition.
  """
  @spec default_trigger(t()) :: atom()
  def default_trigger(definition) do
    definition.triggers
    |> List.first()
    |> Map.fetch!(:name)
  end

  @doc """
  Resolves one named trigger from the workflow definition.
  """
  @spec resolve_trigger(t(), atom()) :: {:ok, atom()} | {:error, trigger_error()}
  def resolve_trigger(definition, trigger_name) when is_atom(trigger_name) do
    case Enum.find(definition.triggers, &(&1.name == trigger_name)) do
      %{name: name} -> {:ok, name}
      nil -> {:error, {:invalid_trigger, trigger_name}}
    end
  end

  @doc """
  Fetches one declared workflow step by name.
  """
  @spec step(t(), atom()) :: {:ok, step()} | {:error, {:unknown_step, atom()}}
  def step(definition, step_name) when is_atom(step_name) do
    case Enum.find(definition.steps, &(&1.name == step_name)) do
      %{} = step -> {:ok, step}
      nil -> {:error, {:unknown_step, step_name}}
    end
  end

  @doc """
  Resolves the transition target for a step outcome.
  """
  @spec transition_target(t(), atom(), atom()) ::
          {:ok, transition_target()} | {:error, {:unknown_transition, atom(), atom()}}
  def transition_target(definition, from_step, outcome)
      when is_atom(from_step) and is_atom(outcome) do
    case Enum.find(definition.transitions, &(&1.from == from_step and &1.on == outcome)) do
      %{to: to_step} -> {:ok, to_step}
      nil -> {:error, {:unknown_transition, from_step, outcome}}
    end
  end

  @doc """
  Resolves the next step after a successful execution.
  """
  @spec next_step_after_success(t(), atom(), [atom() | String.t()]) ::
          {:ok, transition_target()} | {:error, {:no_runnable_step, [atom()]}}
  def next_step_after_success(definition, from_step, completed_steps)
      when is_atom(from_step) and is_list(completed_steps) do
    if dependency_mode?(definition) do
      next_dependency_step(definition, completed_steps)
    else
      transition_target(definition, from_step, :ok)
    end
  end

  @doc """
  Deserializes persisted payload keys back to declared workflow field names.
  """
  @spec deserialize_payload(t() | nil, map()) :: map()
  def deserialize_payload(nil, payload), do: payload

  def deserialize_payload(definition, payload) when is_map(payload) do
    known_fields =
      definition.payload
      |> Enum.map(&{Atom.to_string(&1.name), &1.name})
      |> Map.new()

    Map.new(payload, fn
      {key, value} when is_binary(key) ->
        {Map.get(known_fields, key, key), value}

      entry ->
        entry
    end)
  end

  @doc """
  Serializes a workflow module name for persistence.
  """
  @spec serialize_workflow(module()) :: String.t()
  def serialize_workflow(workflow) when is_atom(workflow), do: Atom.to_string(workflow)

  @doc """
  Serializes a trigger identifier for persistence.
  """
  @spec serialize_trigger(atom() | String.t() | nil) :: String.t() | nil
  def serialize_trigger(nil), do: nil
  def serialize_trigger(trigger) when is_atom(trigger), do: Atom.to_string(trigger)
  def serialize_trigger(trigger) when is_binary(trigger), do: trigger

  @doc """
  Serializes a step identifier for persistence.
  """
  @spec serialize_step(atom() | String.t() | nil) :: String.t() | nil
  def serialize_step(nil), do: nil
  def serialize_step(step) when is_atom(step), do: Atom.to_string(step)
  def serialize_step(step) when is_binary(step), do: step

  @doc """
  Returns true when the workflow uses dependency-based step progression.
  """
  @spec dependency_mode?(t()) :: boolean()
  def dependency_mode?(definition) do
    Enum.any?(definition.steps, fn step ->
      case Keyword.get(step.opts, :after) do
        dependencies when is_list(dependencies) -> dependencies != []
        _other -> false
      end
    end)
  end

  defp next_dependency_step(definition, completed_steps) do
    completed_steps =
      completed_steps
      |> Enum.map(&serialize_step/1)
      |> MapSet.new()

    pending_steps =
      definition.steps
      |> Enum.map(& &1.name)
      |> Enum.reject(fn step_name ->
        MapSet.member?(completed_steps, serialize_step(step_name))
      end)

    cond do
      pending_steps == [] ->
        {:ok, :complete}

      true ->
        definition
        |> dependency_step_order()
        |> Enum.find(fn step_name ->
          step_name in pending_steps and
            dependencies_satisfied?(definition, step_name, completed_steps)
        end)
        |> case do
          nil -> {:error, {:no_runnable_step, pending_steps}}
          step_name -> {:ok, step_name}
        end
    end
  end

  defp dependencies_satisfied?(definition, step_name, completed_steps) do
    definition
    |> dependency_map()
    |> Map.get(step_name, [])
    |> Enum.all?(fn dependency ->
      MapSet.member?(completed_steps, serialize_step(dependency))
    end)
  end

  defp dependency_step_order(definition) do
    phases = dependency_phases(definition)

    declaration_order =
      definition.steps
      |> Enum.map(& &1.name)
      |> Enum.with_index()
      |> Map.new()

    definition.steps
    |> Enum.map(& &1.name)
    |> Enum.sort_by(fn step_name ->
      {Map.fetch!(phases, step_name), Map.fetch!(declaration_order, step_name)}
    end)
  end

  defp dependency_phases(definition) do
    dependencies = dependency_map(definition)
    step_names = definition.steps |> Enum.map(& &1.name)

    {phases, _visiting} =
      Enum.reduce(step_names, {%{}, MapSet.new()}, fn step_name, {phases, visiting} ->
        {phase, phases, visiting} = dependency_phase(step_name, dependencies, phases, visiting)
        {Map.put(phases, step_name, phase), visiting}
      end)

    phases
  end

  defp dependency_phase(step_name, dependencies, phases, visiting) do
    case Map.fetch(phases, step_name) do
      {:ok, phase} ->
        {phase, phases, visiting}

      :error ->
        if MapSet.member?(visiting, step_name) do
          raise ArgumentError, "workflow dependency graph must be acyclic"
        end

        visiting = MapSet.put(visiting, step_name)

        {dependency_phases, phases, visiting} =
          Enum.reduce(Map.get(dependencies, step_name, []), {[], phases, visiting}, fn dependency,
                                                                                       {acc,
                                                                                        phases,
                                                                                        visiting} ->
            {phase, phases, visiting} =
              dependency_phase(dependency, dependencies, phases, visiting)

            {[phase | acc], phases, visiting}
          end)

        phase =
          case dependency_phases do
            [] -> 0
            phases -> Enum.max(phases) + 1
          end

        {phase, Map.put(phases, step_name, phase), MapSet.delete(visiting, step_name)}
    end
  end

  defp dependency_map(definition) do
    Map.new(definition.steps, fn %{name: name, opts: opts} ->
      explicit_dependencies =
        opts
        |> Keyword.get(:after, [])
        |> List.wrap()

      {name, explicit_dependencies}
    end)
  end

  @doc """
  Deserializes a persisted trigger name back to the declared workflow trigger.
  """
  @spec deserialize_trigger(t(), String.t() | nil) :: atom() | String.t() | nil
  def deserialize_trigger(_definition, nil), do: nil

  def deserialize_trigger(definition, trigger_name) when is_binary(trigger_name) do
    Enum.find_value(definition.triggers, trigger_name, fn
      %{name: trigger} ->
        if Atom.to_string(trigger) == trigger_name, do: trigger, else: false
    end)
  end

  @doc """
  Deserializes a persisted step name back to the declared workflow step.
  """
  @spec deserialize_step(t(), String.t() | nil) :: atom() | String.t() | nil
  def deserialize_step(_definition, nil), do: nil

  def deserialize_step(definition, step_name) when is_binary(step_name) do
    Enum.find_value(definition.steps, step_name, fn
      %{name: step} ->
        if Atom.to_string(step) == step_name, do: step, else: false
    end)
  end

  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, _key, %{} = value) when map_size(value) == 0, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp input_matches_type?(value, :string), do: is_binary(value)
  defp input_matches_type?(value, :integer), do: is_integer(value)
  defp input_matches_type?(value, :float), do: is_float(value)
  defp input_matches_type?(value, :boolean), do: is_boolean(value)
  defp input_matches_type?(value, :map), do: is_map(value)
  defp input_matches_type?(value, :list), do: is_list(value)
  defp input_matches_type?(value, :atom), do: is_atom(value)
  defp input_matches_type?(_value, _unknown_type), do: true

  defp deserialize_workflow_name(workflow_name) do
    try do
      {:ok, String.to_existing_atom(workflow_name)}
    rescue
      ArgumentError -> {:error, {:invalid_workflow, workflow_name}}
    end
  end

  defp resolve_default!({:today, :iso8601}), do: Date.utc_today() |> Date.to_iso8601()
  defp resolve_default!({:now, :iso8601}), do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp resolve_default!(default), do: default
end
