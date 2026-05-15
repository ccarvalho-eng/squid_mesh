defmodule SquidMesh.Runtime.DispatchAgent do
  @moduledoc """
  Jido-native dispatch coordination state for one durable dispatch queue.

  The agent is intentionally not wired into the current executor path yet. It is
  a rebuildable read model over dispatch-thread journal entries so the next
  runtime slices can coordinate claims, leases, retries, and workflow wakeups
  from durable facts instead of in-memory state.
  """

  use Jido.Agent,
    name: "squid_mesh_dispatch_agent",
    description: "Rebuildable dispatch coordination state for one Squid Mesh queue.",
    default_plugins: false

  alias Jido.Agent
  alias SquidMesh.Runtime.DispatchProtocol.Projection
  alias SquidMesh.Runtime.Journal
  alias SquidMesh.Runtime.Journal.Checkpoint

  @type queue :: String.t()
  @type storage_config :: Journal.storage_config()

  @spec rebuild(storage_config(), queue() | atom()) :: {:ok, Agent.t()} | {:error, term()}
  def rebuild(storage, queue) do
    queue = normalize_queue(queue)

    with {:ok, loaded_thread} <- Journal.load_thread(storage, {:dispatch, queue}),
         {:ok, projection} <- current_projection(storage, loaded_thread) do
      {:ok,
       new(
         id: agent_id(queue),
         state: %{
           queue: queue,
           projection: projection,
           thread_rev: loaded_thread.rev
         }
       )}
    end
  end

  @spec agent_id(queue() | atom()) :: String.t()
  def agent_id(queue), do: "squid_mesh.dispatch.#{normalize_queue(queue)}"

  @spec visible_attempts(Agent.t(), DateTime.t()) :: [
          SquidMesh.Runtime.DispatchProtocol.ActionAttempt.t()
        ]
  def visible_attempts(
        %Agent{agent_module: __MODULE__, state: %{projection: projection}},
        %DateTime{} = at
      ) do
    Projection.visible_attempts(projection, at)
  end

  @spec expired_claims(Agent.t(), DateTime.t()) :: [
          SquidMesh.Runtime.DispatchProtocol.ActionAttempt.t()
        ]
  def expired_claims(
        %Agent{agent_module: __MODULE__, state: %{projection: projection}},
        %DateTime{} = at
      ) do
    Projection.expired_claims(projection, at)
  end

  @spec completed_results(Agent.t()) :: [SquidMesh.Runtime.DispatchProtocol.ActionAttempt.t()]
  def completed_results(%Agent{agent_module: __MODULE__, state: %{projection: projection}}) do
    Projection.completed_results(projection)
  end

  defp current_projection(storage, %{thread: thread, rev: rev, entries: entries}) do
    with {:ok, projection} <- projection_from_checkpoint(storage, thread, rev, entries),
         {:ok, run_terminal_entries} <- load_run_terminal_entries(storage, entries) do
      {:ok, Projection.replay(projection, run_terminal_entries)}
    end
  end

  defp projection_from_checkpoint(storage, thread, rev, entries) do
    case Journal.fetch_checkpoint(storage, thread) do
      {:ok, %Checkpoint{thread_rev: checkpoint_rev, projection: %Projection{} = projection}}
      when is_integer(checkpoint_rev) and checkpoint_rev >= 0 and checkpoint_rev <= rev ->
        {:ok, Projection.replay(projection, Enum.drop(entries, checkpoint_rev))}

      {:error, :not_found} ->
        {:ok, Projection.rebuild(entries)}

      {:error, _reason} = error ->
        error

      _future_or_invalid_checkpoint ->
        {:ok, Projection.rebuild(entries)}
    end
  end

  defp load_run_terminal_entries(storage, entries) do
    entries
    |> run_ids()
    |> Enum.reduce_while({:ok, []}, fn run_id, {:ok, terminal_entries} ->
      case Journal.load_thread(storage, {:run, run_id}) do
        {:ok, %{entries: run_entries}} ->
          {:cont,
           {:ok, terminal_entries ++ Enum.filter(run_entries, &(&1.type == :run_terminal))}}

        {:error, :not_found} ->
          {:cont, {:ok, terminal_entries}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp run_ids(entries) do
    entries
    |> Enum.map(&Map.get(&1.data, :run_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_queue(nil), do: "default"
  defp normalize_queue(queue) when is_binary(queue), do: queue
  defp normalize_queue(queue), do: to_string(queue)
end
