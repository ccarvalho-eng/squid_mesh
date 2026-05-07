defmodule SquidMesh.Config do
  @moduledoc """
  Loads and validates host application configuration for Squid Mesh.

  This contract is intentionally small so application teams only configure the
  runtime boundary once, while workflow authors stay focused on declarative
  workflow definitions and public API usage.
  """

  @type execution_option ::
          {:name, module() | atom()} | {:queue, atom()} | {:stale_step_timeout, non_neg_integer()}
  @type raw_config :: [repo: module(), execution: [execution_option()]]
  @type t :: %__MODULE__{
          repo: module(),
          execution_name: module() | atom(),
          execution_queue: atom(),
          stale_step_timeout: non_neg_integer()
        }

  defstruct [
    :repo,
    execution_name: Oban,
    execution_queue: :squid_mesh,
    stale_step_timeout: 900_000
  ]

  @default_execution [name: Oban, queue: :squid_mesh, stale_step_timeout: 900_000]

  @type config_error :: {:missing_config, [atom()]} | {:invalid_config, keyword()}

  @spec load(keyword()) :: {:ok, t()} | {:error, config_error()}
  def load(overrides \\ []) do
    config =
      :squid_mesh
      |> Application.get_all_env()
      |> Keyword.merge(overrides)

    with :ok <- validate_required_keys(config),
         {:ok, execution} <-
           validate_execution(
             Keyword.merge(@default_execution, Keyword.get(config, :execution, []))
           ) do
      {:ok,
       %__MODULE__{
         repo: Keyword.fetch!(config, :repo),
         execution_name: Keyword.fetch!(execution, :name),
         execution_queue: Keyword.fetch!(execution, :queue),
         stale_step_timeout: Keyword.fetch!(execution, :stale_step_timeout)
       }}
    end
  end

  @spec load!(keyword()) :: t()
  def load!(overrides \\ []) do
    case load(overrides) do
      {:ok, config} ->
        config

      {:error, {:missing_config, keys}} ->
        keys =
          keys
          |> Enum.map_join(", ", &inspect/1)

        raise ArgumentError,
              "missing Squid Mesh configuration keys: #{keys}"

      {:error, {:invalid_config, details}} ->
        details =
          details
          |> Enum.map_join(", ", fn {key, value} -> "#{inspect(key)}=#{inspect(value)}" end)

        raise ArgumentError,
              "invalid Squid Mesh configuration: #{details}"
    end
  end

  defp validate_required_keys(config) do
    missing_keys =
      [:repo]
      |> Enum.reject(&Keyword.has_key?(config, &1))

    case missing_keys do
      [] -> :ok
      keys -> {:error, {:missing_config, keys}}
    end
  end

  defp validate_execution(execution) do
    case Keyword.fetch!(execution, :stale_step_timeout) do
      timeout when is_integer(timeout) and timeout >= 0 ->
        {:ok, execution}

      invalid ->
        {:error, {:invalid_config, [stale_step_timeout: invalid]}}
    end
  end
end
