defmodule SquidMesh.Runtime.DispatchAgent do
  @moduledoc """
  Jido-native dispatch coordination state for one durable dispatch queue.

  The agent is intentionally not wired into the current executor path yet. It
  rebuilds from dispatch-thread journal entries and performs durable claim
  appends so runtime slices can coordinate leases, retries, and workflow wakeups
  from durable facts instead of in-memory state.
  """

  use Jido.Agent,
    name: "squid_mesh_dispatch_agent",
    description: "Rebuildable dispatch coordination state for one Squid Mesh queue.",
    default_plugins: false

  alias Jido.Agent
  alias SquidMesh.Runtime.DispatchProtocol
  alias SquidMesh.Runtime.DispatchProtocol.ActionAttempt
  alias SquidMesh.Runtime.DispatchProtocol.Projection
  alias SquidMesh.Runtime.Journal
  alias SquidMesh.Runtime.Journal.Checkpoint

  @default_lease_seconds 300

  @type queue :: String.t()
  @type claim :: %{
          required(:agent) => Agent.t(),
          required(:attempt) => ActionAttempt.t(),
          required(:claim_id) => String.t(),
          required(:claim_token) => String.t(),
          required(:lease_until) => DateTime.t()
        }
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

  @spec put_checkpoint(storage_config(), Agent.t(), keyword()) :: :ok | {:error, term()}
  def put_checkpoint(
        storage,
        %Agent{
          agent_module: __MODULE__,
          state: %{queue: queue, projection: projection, thread_rev: thread_rev}
        },
        opts \\ []
      )
      when is_binary(queue) and is_integer(thread_rev) and thread_rev >= 0 and is_list(opts) do
    Journal.put_checkpoint(storage, {:dispatch, queue}, projection, thread_rev, opts)
  end

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

  @spec claim_next(storage_config(), Agent.t(), String.t(), keyword()) ::
          {:ok, claim()} | {:ok, :none} | {:error, term()}
  def claim_next(
        storage,
        %Agent{
          agent_module: __MODULE__,
          state: %{queue: queue, projection: %Projection{} = projection, thread_rev: thread_rev}
        } = agent,
        owner_id,
        opts \\ []
      )
      when is_binary(queue) and is_integer(thread_rev) and thread_rev >= 0 and
             is_binary(owner_id) and is_list(opts) do
    with {:ok, claim_options} <- claim_options(opts) do
      case next_claimable_attempt(projection, claim_options.now) do
        %ActionAttempt{} = attempt ->
          case run_status(storage, attempt.run_id) do
            :active ->
              persist_claim(
                storage,
                agent,
                queue,
                projection,
                thread_rev,
                attempt,
                owner_id,
                claim_options
              )

            :terminal ->
              {:ok, :none}

            {:error, _reason} = error ->
              error
          end

        nil ->
          {:ok, :none}
      end
    end
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
    |> Enum.reduce_while({:ok, []}, fn run_id, {:ok, terminal_entry_chunks} ->
      case Journal.load_thread(storage, {:run, run_id}) do
        {:ok, %{entries: run_entries}} ->
          terminal_entries = Enum.filter(run_entries, &(&1.type == :run_terminal))
          {:cont, {:ok, [terminal_entries | terminal_entry_chunks]}}

        {:error, :not_found} ->
          {:cont, {:ok, terminal_entry_chunks}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, terminal_entry_chunks} ->
        {:ok, terminal_entry_chunks |> Enum.reverse() |> Enum.flat_map(& &1)}

      {:error, _reason} = error ->
        error
    end
  end

  defp run_ids(entries) do
    entries
    |> Enum.map(&Map.get(&1.data, :run_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp persist_claim(
         storage,
         %Agent{} = agent,
         queue,
         %Projection{} = projection,
         thread_rev,
         %ActionAttempt{} = attempt,
         owner_id,
         claim_options
       ) do
    claim_id = Map.fetch!(claim_options, :claim_id)
    claim_token = Map.fetch!(claim_options, :claim_token)
    now = Map.fetch!(claim_options, :now)
    lease_until = DateTime.add(now, Map.fetch!(claim_options, :lease_for), :second)

    attrs = %{
      run_id: attempt.run_id,
      runnable_key: attempt.runnable_key,
      claim_id: claim_id,
      claim_token_hash: claim_token_hash(claim_token),
      owner_id: owner_id,
      queue: queue,
      lease_until: lease_until,
      occurred_at: now
    }

    with {:ok, claim_entry} <- DispatchProtocol.new_entry(:attempt_claimed, attrs),
         {:ok, thread} <- Journal.append_entries(storage, [claim_entry], expected_rev: thread_rev),
         :active <- run_status(storage, attempt.run_id),
         {:ok, claimed_agent} <-
           Agent.set(agent, %{
             projection: Projection.replay(projection, [claim_entry]),
             thread_rev: thread.rev
           }) do
      {:ok,
       %{
         agent: claimed_agent,
         attempt: attempt,
         claim_id: claim_id,
         claim_token: claim_token,
         lease_until: lease_until
       }}
    else
      :terminal -> {:ok, :none}
      {:error, _reason} = error -> error
    end
  end

  defp run_status(storage, run_id) do
    case Journal.load_thread(storage, {:run, run_id}) do
      {:ok, %{entries: entries}} ->
        if Enum.any?(entries, &(&1.type == :run_terminal)) do
          :terminal
        else
          :active
        end

      {:error, :not_found} ->
        :active

      {:error, _reason} = error ->
        error
    end
  end

  defp claim_options(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    lease_for = Keyword.get(opts, :lease_for, @default_lease_seconds)
    claim_id = Keyword.get_lazy(opts, :claim_id, fn -> random_token(16) end)
    claim_token = Keyword.get_lazy(opts, :claim_token, fn -> random_token(32) end)

    cond do
      not match?(%DateTime{}, now) ->
        {:error, {:invalid_option, :now}}

      not (is_integer(lease_for) and lease_for > 0) ->
        {:error, {:invalid_option, :lease_for}}

      not is_binary(claim_id) or claim_id == "" ->
        {:error, {:invalid_option, :claim_id}}

      not is_binary(claim_token) or claim_token == "" ->
        {:error, {:invalid_option, :claim_token}}

      true ->
        {:ok, %{now: now, lease_for: lease_for, claim_id: claim_id, claim_token: claim_token}}
    end
  end

  defp next_claimable_attempt(%Projection{} = projection, %DateTime{} = at) do
    projection
    |> claimable_attempts(at)
    |> Enum.sort_by(&claim_priority/1)
    |> List.first()
  end

  defp claimable_attempts(%Projection{} = projection, %DateTime{} = at) do
    Projection.visible_attempts(projection, at) ++ Projection.expired_claims(projection, at)
  end

  defp claim_priority(%ActionAttempt{} = attempt) do
    {DateTime.to_unix(attempt.visible_at, :microsecond), attempt.run_id, attempt.attempt_number,
     attempt.runnable_key}
  end

  defp claim_token_hash(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode16(case: :lower)
  end

  defp random_token(byte_count) do
    byte_count
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp normalize_queue(nil), do: "default"
  defp normalize_queue(queue) when is_binary(queue), do: queue
  defp normalize_queue(queue), do: to_string(queue)
end
