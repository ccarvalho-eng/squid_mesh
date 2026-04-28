defmodule SquidMesh.Repo.Migrations.CreateSquidMeshRuns do
  use Ecto.Migration

  def change do
    create table(:squid_mesh_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workflow, :string, null: false
      add :status, :string, null: false
      add :input, :map, null: false
      add :context, :map, null: false, default: %{}
      add :current_step, :string
      add :last_error, :map
      add :replayed_from_run_id, references(:squid_mesh_runs, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:squid_mesh_runs, [:workflow])
    create index(:squid_mesh_runs, [:status])
    create index(:squid_mesh_runs, [:inserted_at])
    create index(:squid_mesh_runs, [:replayed_from_run_id])
  end
end
