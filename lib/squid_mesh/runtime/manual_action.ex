defmodule SquidMesh.Runtime.ManualAction do
  @moduledoc """
  Validation and serialization helpers for durable manual workflow actions.

  Pause resume, approval, and rejection flows all persist a small audit payload
  so the read model can reconstruct who acted and when.
  """

  @type attrs :: %{
          optional(:actor) => String.t() | map(),
          optional(:comment) => String.t(),
          optional(:metadata) => map()
        }
  @type type :: :resumed | :approved | :rejected
  @type persisted :: map()

  @spec validate(attrs(), keyword()) :: :ok | {:error, {:invalid_manual_action, map()}}
  def validate(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    required_actor? = Keyword.get(opts, :require_actor, false)

    cond do
      required_actor? and not valid_actor?(Map.get(attrs, :actor)) ->
        {:error, {:invalid_manual_action, %{actor: :required}}}

      Map.has_key?(attrs, :actor) and not valid_actor?(Map.get(attrs, :actor)) ->
        {:error, {:invalid_manual_action, %{actor: :invalid}}}

      Map.has_key?(attrs, :comment) and not valid_comment?(Map.get(attrs, :comment)) ->
        {:error, {:invalid_manual_action, %{comment: :string}}}

      Map.has_key?(attrs, :metadata) and not is_map(Map.get(attrs, :metadata)) ->
        {:error, {:invalid_manual_action, %{metadata: :map}}}

      true ->
        :ok
    end
  end

  @spec build(type(), attrs()) :: persisted()
  def build(type, attrs) when type in [:resumed, :approved, :rejected] and is_map(attrs) do
    %{
      "event" => Atom.to_string(type),
      "at" => DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
    }
    |> maybe_put("actor", Map.get(attrs, :actor))
    |> maybe_put("comment", Map.get(attrs, :comment))
    |> maybe_put("metadata", Map.get(attrs, :metadata))
  end

  defp valid_actor?(actor),
    do: (is_binary(actor) and actor != "") or (is_map(actor) and map_size(actor) > 0)

  defp valid_comment?(comment), do: is_binary(comment) and comment != ""

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
