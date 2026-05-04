defmodule SquidMesh.Runtime.StepInput do
  @moduledoc """
  Step-execution input normalization for the runtime.

  This module keeps payload/context merging and identifier normalization out of
  the main executor flow.
  """

  alias SquidMesh.Run
  alias SquidMesh.StepRunStore

  @type expected_step :: atom() | String.t() | nil

  @spec deserialize_expected_step(expected_step()) ::
          {:ok, atom() | nil} | {:error, {:invalid_step, String.t()}}
  def deserialize_expected_step(nil), do: {:ok, nil}
  def deserialize_expected_step(step) when is_atom(step), do: {:ok, step}

  def deserialize_expected_step(step) when is_binary(step) do
    try do
      {:ok, String.to_existing_atom(step)}
    rescue
      ArgumentError -> {:error, {:invalid_step, step}}
    end
  end

  @spec build_step_input(Run.t()) :: map()
  def build_step_input(%Run{payload: payload, context: context}) do
    payload
    |> Kernel.||(%{})
    |> Map.merge(context || %{})
    |> normalize_map_keys()
  end

  @spec build_dependency_step_input(module(), Run.t()) :: map()
  def build_dependency_step_input(repo, %Run{id: run_id} = run) do
    run
    |> build_step_input()
    |> merge_completed_outputs(StepRunStore.completed_outputs(repo, run_id))
  end

  @spec normalize_map_keys(map()) :: map()
  def normalize_map_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        {to_existing_atom(key), normalize_value(value)}

      {key, value} ->
        {key, normalize_value(value)}
    end)
  end

  defp normalize_value(value) when is_map(value), do: normalize_map_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp merge_completed_outputs(input, outputs) do
    Enum.reduce(outputs, input, fn output, acc -> Map.merge(acc, normalize_map_keys(output)) end)
  end

  defp to_existing_atom(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> key
    end
  end
end
