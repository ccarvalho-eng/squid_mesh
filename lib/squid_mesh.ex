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
  alias SquidMesh.Runtime.Dispatcher

  @doc """
  Loads Squid Mesh configuration from the application environment with optional
  runtime overrides.
  """
  @spec config(keyword()) :: {:ok, Config.t()} | {:error, {:missing_config, [atom()]}}
  defdelegate config(overrides \\ []), to: Config, as: :load

  @doc """
  Loads Squid Mesh configuration and raises if required keys are missing.
  """
  @spec config!(keyword()) :: Config.t()
  defdelegate config!(overrides \\ []), to: Config, as: :load!

  @doc """
  Starts a new workflow run with the given payload through the workflow's
  default trigger.
  """
  @spec start_run(module(), map()) ::
          {:ok, Run.t()}
          | {:error, {:missing_config, [atom()]}}
          | {:error, RunStore.create_error()}
          | {:error, {:dispatch_failed, term()}}
  def start_run(workflow, payload) when is_map(payload) do
    start_run(workflow, payload, [])
  end

  @spec start_run(module(), map(), keyword()) ::
          {:ok, Run.t()}
          | {:error, {:missing_config, [atom()]}}
          | {:error, RunStore.create_error()}
          | {:error, {:dispatch_failed, term()}}
  def start_run(workflow, payload, overrides) when is_map(payload) and is_list(overrides) do
    with {:ok, config} <- Config.load(overrides),
         {:ok, run} <- RunStore.create_run(config.repo, workflow, payload),
         {:ok, _job} <- Dispatcher.dispatch_run(config, run) do
      {:ok, run}
    else
      {:error, reason} when is_tuple(reason) and elem(reason, 0) == :invalid_run ->
        {:error, reason}

      {:error, reason} = error when reason in [:not_found] ->
        error

      {:error, %_{} = reason} ->
        {:error, {:dispatch_failed, reason}}

      {:error, reason} when is_tuple(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:dispatch_failed, reason}}
    end
  end

  def start_run(_workflow, _payload, overrides) when is_list(overrides) do
    {:error, {:invalid_payload, :expected_map}}
  end

  @doc """
  Starts a new workflow run through a named trigger with the given payload.
  """
  @spec start_run(module(), atom(), map()) ::
          {:ok, Run.t()}
          | {:error, {:missing_config, [atom()]}}
          | {:error, RunStore.create_error()}
          | {:error, {:dispatch_failed, term()}}
  def start_run(workflow, trigger_name, payload)
      when is_atom(trigger_name) and is_map(payload) do
    start_run(workflow, trigger_name, payload, [])
  end

  @spec start_run(module(), atom(), map(), keyword()) ::
          {:ok, Run.t()}
          | {:error, {:missing_config, [atom()]}}
          | {:error, RunStore.create_error()}
          | {:error, {:dispatch_failed, term()}}
  def start_run(workflow, trigger_name, payload, overrides)
      when is_atom(trigger_name) and is_map(payload) and is_list(overrides) do
    with {:ok, config} <- Config.load(overrides),
         {:ok, run} <- RunStore.create_run(config.repo, workflow, trigger_name, payload),
         {:ok, _job} <- Dispatcher.dispatch_run(config, run) do
      {:ok, run}
    else
      {:error, reason} when is_tuple(reason) and elem(reason, 0) == :invalid_run ->
        {:error, reason}

      {:error, reason} = error when reason in [:not_found] ->
        error

      {:error, %_{} = reason} ->
        {:error, {:dispatch_failed, reason}}

      {:error, reason} when is_tuple(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:dispatch_failed, reason}}
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

  @doc """
  Lists workflow runs with optional filters.
  """
  @spec list_runs(RunStore.list_filters(), keyword()) ::
          {:ok, [Run.t()]} | {:error, {:missing_config, [atom()]}}
  def list_runs(filters \\ [], overrides \\ []) do
    with {:ok, config} <- Config.load(overrides) do
      RunStore.list_runs(config.repo, filters)
    end
  end

  @doc """
  Requests cancellation for an eligible workflow run.
  """
  @spec cancel_run(Ecto.UUID.t(), keyword()) ::
          {:ok, Run.t()}
          | {:error, :not_found | {:missing_config, [atom()]} | RunStore.transition_error()}
  def cancel_run(run_id, overrides \\ []) do
    with {:ok, config} <- Config.load(overrides) do
      RunStore.cancel_run(config.repo, run_id)
    end
  end

  @doc """
  Creates a new run from a prior run and links it to the original run.
  """
  @spec replay_run(Ecto.UUID.t(), keyword()) ::
          {:ok, Run.t()}
          | {:error, :not_found | {:missing_config, [atom()]} | RunStore.replay_error()}
          | {:error, {:dispatch_failed, term()}}
  def replay_run(run_id, overrides \\ []) do
    with {:ok, config} <- Config.load(overrides),
         {:ok, run} <- RunStore.replay_run(config.repo, run_id),
         {:ok, _job} <- Dispatcher.dispatch_run(config, run) do
      {:ok, run}
    else
      {:error, %_{} = reason} ->
        {:error, {:dispatch_failed, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
