defmodule SquidMesh.Repo.Migrations.AddResumeToSquidMeshStepRuns do
  use Ecto.Migration

  def change do
    alter table(:squid_mesh_step_runs) do
      add :resume, :map
    end
  end
end
