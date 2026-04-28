defmodule SquidMesh.Runtime.StateMachineTest do
  use ExUnit.Case

  alias SquidMesh.Runtime.StateMachine

  describe "states/0" do
    test "enumerates the valid run states" do
      assert StateMachine.states() == [
               :pending,
               :running,
               :retrying,
               :failed,
               :completed,
               :cancelling,
               :cancelled
             ]
    end
  end

  describe "allowed_transitions/1" do
    test "returns the transitions available from a state" do
      assert {:ok, [:running, :failed, :cancelled]} = StateMachine.allowed_transitions(:pending)

      assert {:ok, [:retrying, :failed, :completed, :cancelling]} =
               StateMachine.allowed_transitions(:running)

      assert {:ok, [:cancelled, :failed]} = StateMachine.allowed_transitions(:cancelling)
    end

    test "rejects unknown states" do
      assert {:error, {:unknown_state, :paused}} = StateMachine.allowed_transitions(:paused)
    end
  end

  describe "transition/2" do
    test "accepts valid transitions needed by the executor lifecycle" do
      assert {:ok, :running} = StateMachine.transition(:pending, :running)
      assert {:ok, :retrying} = StateMachine.transition(:running, :retrying)
      assert {:ok, :running} = StateMachine.transition(:retrying, :running)
      assert {:ok, :completed} = StateMachine.transition(:running, :completed)
      assert {:ok, :cancelling} = StateMachine.transition(:running, :cancelling)
      assert {:ok, :cancelled} = StateMachine.transition(:cancelling, :cancelled)
    end

    test "rejects invalid transitions" do
      assert {:error, {:invalid_transition, :pending, :completed}} =
               StateMachine.transition(:pending, :completed)

      assert {:error, {:invalid_transition, :completed, :running}} =
               StateMachine.transition(:completed, :running)

      assert {:error, {:invalid_transition, :cancelled, :retrying}} =
               StateMachine.transition(:cancelled, :retrying)
    end

    test "rejects unknown origin and destination states" do
      assert {:error, {:unknown_state, :paused}} = StateMachine.transition(:paused, :running)
      assert {:error, {:unknown_state, :paused}} = StateMachine.transition(:running, :paused)
    end
  end

  describe "terminal?/1" do
    test "identifies terminal states" do
      assert StateMachine.terminal?(:failed)
      assert StateMachine.terminal?(:completed)
      assert StateMachine.terminal?(:cancelled)

      refute StateMachine.terminal?(:pending)
      refute StateMachine.terminal?(:running)
      refute StateMachine.terminal?(:retrying)
      refute StateMachine.terminal?(:cancelling)
    end
  end

  describe "can_transition?/2" do
    test "returns a boolean view over transition validity" do
      assert StateMachine.can_transition?(:pending, :running)
      assert StateMachine.can_transition?(:running, :failed)

      refute StateMachine.can_transition?(:pending, :completed)
      refute StateMachine.can_transition?(:paused, :running)
    end
  end
end
