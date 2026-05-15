defmodule SquidMesh.Runtime.WorkflowAgentTest do
  use ExUnit.Case, async: false

  alias SquidMesh.Runtime.DispatchAgent
  alias SquidMesh.Runtime.DispatchProtocol
  alias SquidMesh.Runtime.DispatchProtocol.Entry
  alias SquidMesh.Runtime.Journal
  alias SquidMesh.Runtime.WorkflowAgent
  alias SquidMesh.Runtime.WorkflowAgent.Projection

  @storage {Jido.Storage.ETS, table: :squid_mesh_workflow_agent_test}
  @run_id "run_123"
  @workflow "BillingWorkflow"
  @runnable_key "run_123:charge_card:1"
  @idempotency_key "run_123:charge_card:payment_456"
  @started_at ~U[2026-05-15 00:00:00Z]
  @visible_at ~U[2026-05-15 00:00:10Z]
  @claimed_at ~U[2026-05-15 00:00:20Z]
  @completed_at ~U[2026-05-15 00:00:40Z]
  @lease_until ~U[2026-05-15 00:01:00Z]

  setup do
    cleanup_storage()

    on_exit(fn ->
      cleanup_storage()
    end)
  end

  test "rebuilds a keyed workflow agent from durable run entries" do
    assert {:ok, run_started} =
             DispatchProtocol.new_entry(:run_started, %{
               run_id: @run_id,
               workflow: @workflow,
               occurred_at: @started_at
             })

    assert {:ok, runnables_planned} =
             DispatchProtocol.new_entry(:runnables_planned, %{
               run_id: @run_id,
               runnables: [%{runnable_key: @runnable_key, step: "charge_card"}],
               occurred_at: @visible_at
             })

    assert {:ok, %{rev: 2}} = Journal.append_entries(@storage, [run_started, runnables_planned])

    assert {:ok, agent} = WorkflowAgent.rebuild(@storage, @run_id)

    assert agent.id == "squid_mesh.workflow.run_123"
    assert agent.state.run_id == @run_id
    assert agent.state.workflow == @workflow
    assert agent.state.thread_rev == 2
    assert %Projection{} = agent.state.projection
    assert WorkflowAgent.status(agent) == :running
    assert WorkflowAgent.applied_runnable_keys(agent) == MapSet.new()
  end

  test "uses a current checkpoint instead of replaying the full run thread" do
    assert {:ok, run_started} =
             DispatchProtocol.new_entry(:run_started, %{
               run_id: @run_id,
               workflow: @workflow,
               occurred_at: @started_at
             })

    assert {:ok, thread} = Journal.append_entries(@storage, [run_started])

    checkpoint_projection = %Projection{
      run_id: @run_id,
      workflow: @workflow,
      status: :running,
      planned_runnables: %{@runnable_key => %{runnable_key: @runnable_key}}
    }

    assert :ok =
             Journal.put_checkpoint(@storage, {:run, @run_id}, checkpoint_projection, thread.rev,
               updated_at: @visible_at
             )

    assert {:ok, agent} = WorkflowAgent.rebuild(@storage, @run_id)

    assert agent.state.projection == checkpoint_projection
    assert WorkflowAgent.planned_runnable_keys(agent) == [@runnable_key]
  end

  test "persists a checkpoint from the rebuilt workflow agent state" do
    assert {:ok, run_started} =
             DispatchProtocol.new_entry(:run_started, %{
               run_id: @run_id,
               workflow: @workflow,
               occurred_at: @started_at
             })

    assert {:ok, runnables_planned} =
             DispatchProtocol.new_entry(:runnables_planned, %{
               run_id: @run_id,
               runnables: [%{runnable_key: @runnable_key, step: "charge_card"}],
               occurred_at: @visible_at
             })

    assert {:ok, %{rev: 2}} = Journal.append_entries(@storage, [run_started, runnables_planned])
    assert {:ok, agent} = WorkflowAgent.rebuild(@storage, @run_id)

    assert :ok = WorkflowAgent.put_checkpoint(@storage, agent, updated_at: @completed_at)

    assert {:ok,
            %{
              thread: {:run, @run_id},
              thread_rev: 2,
              projection: %Projection{} = checkpoint_projection,
              updated_at: @completed_at
            }} = Journal.fetch_checkpoint(@storage, {:run, @run_id})

    assert Projection.planned_runnable_keys(checkpoint_projection) == [@runnable_key]
  end

  test "replays entries newer than a stale workflow checkpoint" do
    checkpoint_runnable_key = "run_123:refund_card:1"

    assert {:ok, run_started} =
             DispatchProtocol.new_entry(:run_started, %{
               run_id: @run_id,
               workflow: @workflow,
               occurred_at: @started_at
             })

    assert {:ok, applied} =
             DispatchProtocol.new_entry(:runnable_applied, %{
               run_id: @run_id,
               runnable_key: checkpoint_runnable_key,
               occurred_at: @completed_at
             })

    assert {:ok, thread} = Journal.append_entries(@storage, [run_started])

    checkpoint_projection = %Projection{
      run_id: @run_id,
      workflow: @workflow,
      status: :running,
      planned_runnables: %{checkpoint_runnable_key => %{runnable_key: checkpoint_runnable_key}}
    }

    assert :ok =
             Journal.put_checkpoint(@storage, {:run, @run_id}, checkpoint_projection, thread.rev,
               updated_at: @visible_at
             )

    assert {:ok, %{rev: 2}} = Journal.append_entries(@storage, [applied], expected_rev: 1)

    assert {:ok, agent} = WorkflowAgent.rebuild(@storage, @run_id)

    assert agent.state.thread_rev == 2
    assert WorkflowAgent.status(agent) == :idle
    assert WorkflowAgent.applied_runnable_keys(agent) == MapSet.new([checkpoint_runnable_key])
  end

  test "keeps completed dispatch results pending until the workflow applies them" do
    assert {:ok, run_started} =
             DispatchProtocol.new_entry(:run_started, %{
               run_id: @run_id,
               workflow: @workflow,
               occurred_at: @started_at
             })

    assert {:ok, runnables_planned} =
             DispatchProtocol.new_entry(:runnables_planned, %{
               run_id: @run_id,
               runnables: [%{runnable_key: @runnable_key, step: "charge_card"}],
               occurred_at: @visible_at
             })

    assert {:ok, dispatch_scheduled} =
             DispatchProtocol.new_entry(:attempt_scheduled, scheduled_attrs())

    assert {:ok, dispatch_claimed} =
             DispatchProtocol.new_entry(:attempt_claimed, claimed_attrs())

    assert {:ok, dispatch_completed} =
             DispatchProtocol.new_entry(:attempt_completed, completed_attrs())

    assert {:ok, _run_thread} = Journal.append_entries(@storage, [run_started, runnables_planned])

    assert {:ok, _dispatch_thread} =
             Journal.append_entries(@storage, [
               dispatch_scheduled,
               dispatch_claimed,
               dispatch_completed
             ])

    assert {:ok, workflow_agent} = WorkflowAgent.rebuild(@storage, @run_id)
    assert {:ok, dispatch_agent} = DispatchAgent.rebuild(@storage, "default")

    assert [%{runnable_key: @runnable_key, status: :completed}] =
             WorkflowAgent.pending_results(workflow_agent, dispatch_agent)

    assert {:ok, applied} =
             DispatchProtocol.new_entry(:runnable_applied, %{
               run_id: @run_id,
               runnable_key: @runnable_key,
               occurred_at: @completed_at
             })

    assert {:ok, _thread} = Journal.append_entries(@storage, [applied], expected_rev: 2)
    assert {:ok, applied_workflow_agent} = WorkflowAgent.rebuild(@storage, @run_id)

    assert WorkflowAgent.pending_results(applied_workflow_agent, dispatch_agent) == []
  end

  test "ignores completed dispatch results for unplanned runnable keys in the same run" do
    stale_runnable_key = "run_123:stale_step:1"

    assert {:ok, run_started} =
             DispatchProtocol.new_entry(:run_started, %{
               run_id: @run_id,
               workflow: @workflow,
               occurred_at: @started_at
             })

    assert {:ok, runnables_planned} =
             DispatchProtocol.new_entry(:runnables_planned, %{
               run_id: @run_id,
               runnables: [%{runnable_key: @runnable_key, step: "charge_card"}],
               occurred_at: @visible_at
             })

    assert {:ok, stale_scheduled} =
             DispatchProtocol.new_entry(
               :attempt_scheduled,
               scheduled_attrs(runnable_key: stale_runnable_key)
             )

    assert {:ok, stale_claimed} =
             DispatchProtocol.new_entry(
               :attempt_claimed,
               claimed_attrs(runnable_key: stale_runnable_key)
             )

    assert {:ok, stale_completed} =
             DispatchProtocol.new_entry(
               :attempt_completed,
               completed_attrs(runnable_key: stale_runnable_key)
             )

    assert {:ok, _run_thread} = Journal.append_entries(@storage, [run_started, runnables_planned])

    assert {:ok, _dispatch_thread} =
             Journal.append_entries(@storage, [stale_scheduled, stale_claimed, stale_completed])

    assert {:ok, workflow_agent} = WorkflowAgent.rebuild(@storage, @run_id)
    assert {:ok, dispatch_agent} = DispatchAgent.rebuild(@storage, "default")

    assert WorkflowAgent.pending_results(workflow_agent, dispatch_agent) == []
  end

  test "ignores completed dispatch results from other runs on the same queue" do
    other_run_id = "run_456"
    other_runnable_key = "run_456:charge_card:1"

    assert {:ok, run_started} =
             DispatchProtocol.new_entry(:run_started, %{
               run_id: @run_id,
               workflow: @workflow,
               occurred_at: @started_at
             })

    assert {:ok, runnables_planned} =
             DispatchProtocol.new_entry(:runnables_planned, %{
               run_id: @run_id,
               runnables: [%{runnable_key: @runnable_key, step: "charge_card"}],
               occurred_at: @visible_at
             })

    assert {:ok, other_scheduled} =
             DispatchProtocol.new_entry(
               :attempt_scheduled,
               scheduled_attrs(
                 run_id: other_run_id,
                 runnable_key: other_runnable_key,
                 idempotency_key: "#{other_run_id}:charge_card:payment_789"
               )
             )

    assert {:ok, other_claimed} =
             DispatchProtocol.new_entry(
               :attempt_claimed,
               claimed_attrs(run_id: other_run_id, runnable_key: other_runnable_key)
             )

    assert {:ok, other_completed} =
             DispatchProtocol.new_entry(
               :attempt_completed,
               completed_attrs(run_id: other_run_id, runnable_key: other_runnable_key)
             )

    assert {:ok, _run_thread} = Journal.append_entries(@storage, [run_started, runnables_planned])

    assert {:ok, _dispatch_thread} =
             Journal.append_entries(@storage, [other_scheduled, other_claimed, other_completed])

    assert {:ok, workflow_agent} = WorkflowAgent.rebuild(@storage, @run_id)
    assert {:ok, dispatch_agent} = DispatchAgent.rebuild(@storage, "default")

    assert WorkflowAgent.pending_results(workflow_agent, dispatch_agent) == []
  end

  test "records anomalies instead of raising for malformed persisted workflow entries" do
    malformed_entries = [
      workflow_entry(:run_started, %{}),
      workflow_entry(:runnables_planned, %{run_id: @run_id, runnables: :not_a_list}),
      workflow_entry(:runnable_applied, %{run_id: @run_id}),
      workflow_entry(:run_terminal, %{run_id: @run_id})
    ]

    projection = Projection.rebuild(malformed_entries)

    assert Projection.status(projection) == :new
    assert Projection.planned_runnable_keys(projection) == []
    assert Projection.applied_runnable_keys(projection) == MapSet.new()

    assert [
             %{entry_type: :run_started, reason: :malformed_entry},
             %{entry_type: :runnables_planned, reason: :malformed_entry, run_id: @run_id},
             %{entry_type: :runnable_applied, reason: :malformed_entry, run_id: @run_id},
             %{entry_type: :run_terminal, reason: :malformed_entry, run_id: @run_id}
           ] = Projection.anomalies(projection)
  end

  defp scheduled_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        run_id: @run_id,
        runnable_key: @runnable_key,
        idempotency_key: @idempotency_key,
        attempt_number: 1,
        queue: "default",
        step: "charge_card",
        input: %{"payment_id" => "pay_123"},
        visible_at: @visible_at,
        occurred_at: @visible_at
      },
      Map.new(attrs)
    )
  end

  defp claimed_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        run_id: @run_id,
        runnable_key: @runnable_key,
        claim_id: "claim_1",
        claim_token_hash: "token_hash_1",
        owner_id: "worker_1",
        queue: "default",
        lease_until: @lease_until,
        occurred_at: @claimed_at
      },
      Map.new(attrs)
    )
  end

  defp completed_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        run_id: @run_id,
        runnable_key: @runnable_key,
        claim_id: "claim_1",
        claim_token_hash: "token_hash_1",
        queue: "default",
        result: %{"status" => "captured"},
        occurred_at: @completed_at
      },
      Map.new(attrs)
    )
  end

  defp workflow_entry(type, data) do
    %Entry{
      type: type,
      thread: {:run, @run_id},
      data: data,
      occurred_at: @started_at
    }
  end

  defp cleanup_storage do
    for suffix <- [:checkpoints, :threads, :thread_meta] do
      table = :"squid_mesh_workflow_agent_test_#{suffix}"

      if :ets.whereis(table) != :undefined do
        :ets.delete(table)
      end
    end
  end
end
