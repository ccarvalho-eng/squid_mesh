defmodule SquidMesh.Runtime.DispatchAgentTest do
  use ExUnit.Case, async: false

  alias SquidMesh.Runtime.DispatchAgent
  alias SquidMesh.Runtime.DispatchProtocol
  alias SquidMesh.Runtime.DispatchProtocol.Projection
  alias SquidMesh.Runtime.Journal

  @storage {Jido.Storage.ETS, table: :squid_mesh_dispatch_agent_test}
  @run_id "run_123"
  @runnable_key "run_123:charge_card:1"
  @idempotency_key "run_123:charge_card:payment_456"
  @started_at ~U[2026-05-15 00:00:00Z]
  @visible_at ~U[2026-05-15 00:00:10Z]
  @claimed_at ~U[2026-05-15 00:00:20Z]
  @lease_until ~U[2026-05-15 00:01:00Z]
  @expired_at ~U[2026-05-15 00:02:00Z]

  setup do
    cleanup_storage()

    on_exit(fn ->
      cleanup_storage()
    end)
  end

  test "rebuilds a keyed dispatch agent from durable dispatch entries" do
    assert {:ok, scheduled_entry} =
             DispatchProtocol.new_entry(:attempt_scheduled, scheduled_attrs())

    assert {:ok, claimed_entry} =
             DispatchProtocol.new_entry(:attempt_claimed, claimed_attrs())

    assert {:ok, %{rev: 2}} = Journal.append_entries(@storage, [scheduled_entry, claimed_entry])

    assert {:ok, agent} = DispatchAgent.rebuild(@storage, "default")

    assert agent.id == "squid_mesh.dispatch.default"
    assert agent.state.queue == "default"
    assert agent.state.thread_rev == 2
    assert %Projection{} = agent.state.projection
    assert DispatchAgent.visible_attempts(agent, @visible_at) == []

    assert [
             %{runnable_key: @runnable_key, claim_id: "claim_1", owner_id: "worker_1"}
           ] = DispatchAgent.expired_claims(agent, @expired_at)
  end

  test "uses a current checkpoint instead of replaying the full dispatch thread" do
    assert {:ok, scheduled_entry} =
             DispatchProtocol.new_entry(:attempt_scheduled, scheduled_attrs())

    assert {:ok, thread} = Journal.append_entries(@storage, [scheduled_entry])

    checkpoint_projection = %Projection{}

    assert :ok =
             Journal.put_checkpoint(
               @storage,
               {:dispatch, "default"},
               checkpoint_projection,
               thread.rev,
               updated_at: @visible_at
             )

    assert {:ok, agent} = DispatchAgent.rebuild(@storage, "default")

    assert agent.state.projection == checkpoint_projection
    assert agent.state.thread_rev == thread.rev
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
        occurred_at: @started_at
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

  defp cleanup_storage do
    for suffix <- [:checkpoints, :threads, :thread_meta] do
      table = :"squid_mesh_dispatch_agent_test_#{suffix}"

      if :ets.whereis(table) != :undefined do
        :ets.delete(table)
      end
    end
  end
end
