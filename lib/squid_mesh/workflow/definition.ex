defmodule SquidMesh.Workflow.Definition do
  @moduledoc false

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
          entry_step: atom()
        }

  @type load_error :: {:invalid_workflow, module() | String.t()}
  @type trigger_error :: {:invalid_trigger, atom() | String.t()}
  @type payload_error_details :: %{
          optional(:missing_fields) => [atom()],
          optional(:unknown_fields) => [atom() | String.t()],
          optional(:invalid_types) => %{optional(atom()) => atom()}
        }
  @type transition_target :: atom() | :complete

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

  @spec load_serialized(String.t()) :: {:ok, module(), t()} | {:error, load_error()}
  def load_serialized(workflow_name) when is_binary(workflow_name) do
    workflow = String.to_atom(workflow_name)

    case load(workflow) do
      {:ok, definition} -> {:ok, workflow, definition}
      {:error, _reason} -> {:error, {:invalid_workflow, workflow_name}}
    end
  end

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

  @spec entry_step(t()) :: atom()
  def entry_step(definition), do: definition.entry_step

  @spec default_trigger(t()) :: atom()
  def default_trigger(definition) do
    definition.triggers
    |> List.first()
    |> Map.fetch!(:name)
  end

  @spec resolve_trigger(t(), atom()) :: {:ok, atom()} | {:error, trigger_error()}
  def resolve_trigger(definition, trigger_name) when is_atom(trigger_name) do
    case Enum.find(definition.triggers, &(&1.name == trigger_name)) do
      %{name: name} -> {:ok, name}
      nil -> {:error, {:invalid_trigger, trigger_name}}
    end
  end

  @spec step(t(), atom()) :: {:ok, step()} | {:error, {:unknown_step, atom()}}
  def step(definition, step_name) when is_atom(step_name) do
    case Enum.find(definition.steps, &(&1.name == step_name)) do
      %{} = step -> {:ok, step}
      nil -> {:error, {:unknown_step, step_name}}
    end
  end

  @spec transition_target(t(), atom(), atom()) ::
          {:ok, transition_target()} | {:error, {:unknown_transition, atom(), atom()}}
  def transition_target(definition, from_step, outcome)
      when is_atom(from_step) and is_atom(outcome) do
    case Enum.find(definition.transitions, &(&1.from == from_step and &1.on == outcome)) do
      %{to: to_step} -> {:ok, to_step}
      nil -> {:error, {:unknown_transition, from_step, outcome}}
    end
  end

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

  @spec serialize_workflow(module()) :: String.t()
  def serialize_workflow(workflow) when is_atom(workflow), do: Atom.to_string(workflow)

  @spec serialize_trigger(atom() | String.t() | nil) :: String.t() | nil
  def serialize_trigger(nil), do: nil
  def serialize_trigger(trigger) when is_atom(trigger), do: Atom.to_string(trigger)
  def serialize_trigger(trigger) when is_binary(trigger), do: trigger

  @spec serialize_step(atom() | String.t() | nil) :: String.t() | nil
  def serialize_step(nil), do: nil
  def serialize_step(step) when is_atom(step), do: Atom.to_string(step)
  def serialize_step(step) when is_binary(step), do: step

  @spec deserialize_trigger(t(), String.t() | nil) :: atom() | String.t() | nil
  def deserialize_trigger(_definition, nil), do: nil

  def deserialize_trigger(definition, trigger_name) when is_binary(trigger_name) do
    Enum.find_value(definition.triggers, trigger_name, fn
      %{name: trigger} ->
        if Atom.to_string(trigger) == trigger_name, do: trigger, else: false
    end)
  end

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

  defp resolve_default!({:today, :iso8601}), do: Date.utc_today() |> Date.to_iso8601()
  defp resolve_default!(default), do: default
end
