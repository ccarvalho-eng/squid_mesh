defmodule SquidMesh.Runtime.StateMachine do
  @moduledoc """
  Explicit run lifecycle state machine for the Squid Mesh runtime.

  The runtime coordinator and the later Jido-backed executor should consume
  this module as the single source of truth for valid run-state transitions.
  It defines the workflow run lifecycle without mixing in step execution or
  persistence concerns.
  """

  alias SquidMesh.Run

  @type state :: Run.status()
  @type transition_error ::
          {:unknown_state, atom()}
          | {:invalid_transition, from_state :: state(), to_state :: state()}

  @states [:pending, :running, :retrying, :failed, :completed, :cancelling, :cancelled]

  @transitions %{
    pending: [:running, :failed, :cancelled],
    running: [:retrying, :failed, :completed, :cancelling],
    retrying: [:running, :failed, :cancelling],
    failed: [],
    completed: [],
    cancelling: [:cancelled, :failed],
    cancelled: []
  }

  @doc """
  Returns all valid run states.
  """
  @spec states() :: [state()]
  def states do
    @states
  end

  @doc """
  Returns the states that may be reached directly from the current state.
  """
  @spec allowed_transitions(state()) :: {:ok, [state()]} | {:error, {:unknown_state, atom()}}
  def allowed_transitions(state) do
    case Map.fetch(@transitions, state) do
      {:ok, transitions} -> {:ok, transitions}
      :error -> {:error, {:unknown_state, state}}
    end
  end

  @doc """
  Reports whether a state is terminal.
  """
  @spec terminal?(state()) :: boolean()
  def terminal?(state) do
    case allowed_transitions(state) do
      {:ok, []} -> true
      {:ok, _transitions} -> false
      {:error, _reason} -> false
    end
  end

  @doc """
  Reports whether a transition is valid.
  """
  @spec can_transition?(state(), state()) :: boolean()
  def can_transition?(from_state, to_state) do
    match?({:ok, ^to_state}, transition(from_state, to_state))
  end

  @doc """
  Validates a requested state transition.
  """
  @spec transition(state(), state()) :: {:ok, state()} | {:error, transition_error()}
  def transition(from_state, to_state) do
    with {:ok, transitions} <- allowed_transitions(from_state),
         {:ok, _next_transitions} <- allowed_transitions(to_state) do
      if to_state in transitions do
        {:ok, to_state}
      else
        {:error, {:invalid_transition, from_state, to_state}}
      end
    end
  end
end
