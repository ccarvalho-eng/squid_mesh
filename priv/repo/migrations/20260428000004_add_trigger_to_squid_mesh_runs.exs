defmodule SquidMesh.Repo.Migrations.AddTriggerToSquidMeshRuns do
  use Ecto.Migration

  def change do
    alter table(:squid_mesh_runs) do
      add(:trigger, :string, null: false, default: "manual")
    end

    alter table(:squid_mesh_runs) do
      modify(:trigger, :string, null: false, default: nil)
    end
  end
end
