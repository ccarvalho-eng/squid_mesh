defmodule SquidMesh.Repo.Migrations.AddManualToSquidMeshStepRuns do
  use Ecto.Migration

  def change do
    alter table(:squid_mesh_step_runs) do
      add :manual, :map
    end
  end
end
