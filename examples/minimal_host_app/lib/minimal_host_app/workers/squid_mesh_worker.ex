defmodule MinimalHostApp.Workers.SquidMeshWorker do
  @moduledoc """
  Generic Oban delivery adapter for Squid Mesh executor payloads.
  """

  use Oban.Worker, queue: :squid_mesh, max_attempts: 1

  alias SquidMesh.Runtime.Runner

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    Runner.perform(args)
  end
end
