defmodule SquidMesh.Config do
  @moduledoc """
  Loads and validates host application configuration for Squid Mesh.

  This contract is intentionally small so application teams only configure the
  runtime boundary once, while workflow authors stay focused on declarative
  workflow definitions and public API usage.
  """

  @type execution_option :: {:name, module() | atom()} | {:queue, atom()}
  @type raw_config :: [repo: module(), execution: [execution_option()]]
  @type t :: %__MODULE__{
          repo: module(),
          execution_name: module() | atom(),
          execution_queue: atom()
        }

  defstruct [:repo, execution_name: Oban, execution_queue: :squid_mesh]

  @default_execution [name: Oban, queue: :squid_mesh]

  @spec load(keyword()) :: {:ok, t()} | {:error, {:missing_config, [atom()]}}
  def load(overrides \\ []) do
    config =
      :squid_mesh
      |> Application.get_all_env()
      |> Keyword.merge(overrides)

    with :ok <- validate_required_keys(config) do
      execution = Keyword.merge(@default_execution, Keyword.get(config, :execution, []))

      {:ok,
       %__MODULE__{
         repo: Keyword.fetch!(config, :repo),
         execution_name: Keyword.fetch!(execution, :name),
         execution_queue: Keyword.fetch!(execution, :queue)
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
end
