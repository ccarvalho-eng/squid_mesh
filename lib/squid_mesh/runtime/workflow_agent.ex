defmodule SquidMesh.Runtime.WorkflowAgent do
  @moduledoc """
  Jido-native workflow coordination state for one durable workflow run.

  The agent rebuilds from run-thread journal entries and checkpoints. It does
  not execute workflow steps or mutate the existing runtime tables; it provides
  the restartable coordination state needed by the Jido-native runtime path.
  """

  use Jido.Agent,
    name: "squid_mesh_workflow_agent",
    description: "Rebuildable workflow coordination state for one Squid Mesh run.",
    default_plugins: false

  alias Jido.Agent
  alias SquidMesh.Runtime.DispatchAgent
  alias SquidMesh.Runtime.DispatchProtocol
  alias SquidMesh.Runtime.DispatchProtocol.ActionAttempt
  alias SquidMesh.Runtime.WorkflowAgent.Projection
  alias SquidMesh.Runtime.Journal
  alias SquidMesh.Runtime.Journal.Checkpoint

  @type run_id :: String.t()
  @type apply_update :: %{
          required(:agent) => Agent.t(),
          required(:attempt) => ActionAttempt.t()
        }
  @type storage_config :: Journal.storage_config()

  @spec rebuild(storage_config(), run_id()) :: {:ok, Agent.t()} | {:error, term()}
  def rebuild(storage, run_id) when is_binary(run_id) do
    with {:ok, loaded_thread} <- Journal.load_thread(storage, {:run, run_id}),
         {:ok, projection} <- current_projection(storage, loaded_thread) do
      {:ok,
       new(
         id: agent_id(run_id),
         state: %{
           run_id: run_id,
           workflow: projection.workflow,
           projection: projection,
           thread_rev: loaded_thread.rev
         }
       )}
    end
  end

  @spec agent_id(run_id()) :: String.t()
  def agent_id(run_id), do: "squid_mesh.workflow.#{run_id}"

  @spec put_checkpoint(storage_config(), Agent.t(), keyword()) :: :ok | {:error, term()}
  def put_checkpoint(
        storage,
        %Agent{
          agent_module: __MODULE__,
          state: %{run_id: run_id, projection: projection, thread_rev: thread_rev}
        },
        opts \\ []
      )
      when is_binary(run_id) and is_integer(thread_rev) and thread_rev >= 0 and is_list(opts) do
    Journal.put_checkpoint(storage, {:run, run_id}, projection, thread_rev, opts)
  end

  @spec status(Agent.t()) :: atom()
  def status(%Agent{agent_module: __MODULE__, state: %{projection: projection}}) do
    Projection.status(projection)
  end

  @spec planned_runnable_keys(Agent.t()) :: [String.t()]
  def planned_runnable_keys(%Agent{agent_module: __MODULE__, state: %{projection: projection}}) do
    Projection.planned_runnable_keys(projection)
  end

  @spec applied_runnable_keys(Agent.t()) :: MapSet.t(String.t())
  def applied_runnable_keys(%Agent{agent_module: __MODULE__, state: %{projection: projection}}) do
    Projection.applied_runnable_keys(projection)
  end

  @spec pending_results(Agent.t(), Agent.t()) :: [
          SquidMesh.Runtime.DispatchProtocol.ActionAttempt.t()
        ]
  def pending_results(
        %Agent{agent_module: __MODULE__, state: %{run_id: run_id, projection: projection}},
        %Agent{agent_module: DispatchAgent} = dispatch_agent
      ) do
    applied_keys = Projection.applied_runnable_keys(projection)

    dispatch_agent
    |> DispatchAgent.completed_results()
    |> Enum.filter(&(&1.run_id == run_id))
    |> Enum.filter(&Projection.planned_runnable_key?(projection, &1.runnable_key))
    |> Enum.reject(&MapSet.member?(applied_keys, &1.runnable_key))
    |> reject_when_terminal(projection)
  end

  @doc """
  Records that a durable dispatch completion has been applied to the workflow run.

  The dispatch attempt must be completed, belong to the workflow agent's run,
  and reference a planned runnable that has not already been applied. Stale
  workflow-agent callers race at the run-thread append boundary and receive
  `{:error, :conflict}` from the journal.
  """
  @spec apply_result(storage_config(), Agent.t(), ActionAttempt.t(), keyword()) ::
          {:ok, apply_update()} | {:error, term()}
  def apply_result(storage, agent, attempt, opts \\ [])

  def apply_result(
        storage,
        %Agent{
          agent_module: __MODULE__,
          state: %{run_id: run_id, projection: %Projection{} = projection, thread_rev: thread_rev}
        } = agent,
        %ActionAttempt{} = attempt,
        opts
      )
      when is_binary(run_id) and is_integer(thread_rev) and thread_rev >= 0 and is_list(opts) do
    with {:ok, now} <- apply_now(opts),
         {:ok, target} <- apply_target(projection, run_id, attempt),
         {:pending, %ActionAttempt{} = pending_attempt} <- target,
         {:ok, applied_entry} <-
           DispatchProtocol.new_entry(:runnable_applied, %{
             run_id: pending_attempt.run_id,
             runnable_key: pending_attempt.runnable_key,
             result: pending_attempt.result,
             occurred_at: now
           }),
         {:ok, applied_agent} <-
           persist_workflow_entry(storage, agent, projection, thread_rev, applied_entry) do
      {:ok, %{agent: applied_agent, attempt: pending_attempt}}
    else
      {:applied, %ActionAttempt{} = applied_attempt} ->
        {:ok, %{agent: agent, attempt: applied_attempt}}

      {:error, _reason} = error ->
        error
    end
  end

  defp reject_when_terminal(results, %Projection{} = projection) do
    if Projection.terminal?(projection), do: [], else: results
  end

  defp persist_workflow_entry(
         storage,
         %Agent{} = agent,
         %Projection{} = projection,
         thread_rev,
         entry
       ) do
    with {:ok, thread} <- Journal.append_entries(storage, [entry], expected_rev: thread_rev) do
      {:ok, apply_workflow_entry(agent, projection, entry, thread.rev)}
    end
  end

  defp apply_workflow_entry(%Agent{} = agent, %Projection{} = projection, entry, thread_rev) do
    %Agent{
      agent
      | state: %{
          agent.state
          | projection: Projection.replay(projection, [entry]),
            thread_rev: thread_rev
        }
    }
  end

  defp apply_now(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    if match?(%DateTime{}, now) do
      {:ok, now}
    else
      {:error, {:invalid_option, :now}}
    end
  end

  defp apply_target(%Projection{} = projection, run_id, %ActionAttempt{} = attempt) do
    cond do
      attempt.status != :completed ->
        {:error, :result_not_completed}

      not is_map(attempt.result) ->
        {:error, :missing_result}

      attempt.run_id != run_id ->
        {:error, :wrong_run}

      Projection.terminal?(projection) ->
        {:error, :terminal_run}

      not Projection.planned_runnable_key?(projection, attempt.runnable_key) ->
        {:error, :unknown_runnable_intent}

      MapSet.member?(Projection.applied_runnable_keys(projection), attempt.runnable_key) ->
        apply_duplicate_target(projection, attempt)

      true ->
        {:ok, {:pending, attempt}}
    end
  end

  defp apply_duplicate_target(%Projection{} = projection, %ActionAttempt{} = attempt) do
    case Projection.applied_result(projection, attempt.runnable_key) do
      {:ok, result} when result == attempt.result ->
        {:ok, {:applied, attempt}}

      {:ok, _other_result} ->
        {:error, {:conflicting_result, attempt.runnable_key}}

      :error ->
        {:error, {:conflicting_result, attempt.runnable_key}}
    end
  end

  defp current_projection(storage, %{thread: thread, rev: rev, entries: entries}) do
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
end
