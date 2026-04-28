defmodule SquidMesh do
  @moduledoc """
  Public entrypoint for the Squid Mesh runtime.

  The API exposed here stays focused on declarative workflow operations. Host
  applications start, inspect, and later control runs through this surface
  without needing to work directly with persistence internals.
  """

  alias SquidMesh.Config
  alias SquidMesh.Run
  alias SquidMesh.RunStore

  @spec config(keyword()) :: {:ok, Config.t()} | {:error, {:missing_config, [atom()]}}
  defdelegate config(overrides \\ []), to: Config, as: :load

  @spec config!(keyword()) :: Config.t()
  defdelegate config!(overrides \\ []), to: Config, as: :load!

  @doc """
  Starts a new workflow run with the given input payload.
  """
  @spec start_run(module(), map(), keyword()) ::
          {:ok, Run.t()}
          | {:error, {:missing_config, [atom()]}}
          | {:error, RunStore.create_error()}
  def start_run(workflow, input, overrides \\ []) do
    with {:ok, config} <- Config.load(overrides) do
      RunStore.create_run(config.repo, workflow, input)
    end
  end

  @doc """
  Fetches one workflow run by id.
  """
  @spec inspect_run(Ecto.UUID.t(), keyword()) ::
          {:ok, Run.t()} | {:error, :not_found | {:missing_config, [atom()]}}
  def inspect_run(run_id, overrides \\ []) do
    with {:ok, config} <- Config.load(overrides) do
      RunStore.get_run(config.repo, run_id)
    end
  end
end
