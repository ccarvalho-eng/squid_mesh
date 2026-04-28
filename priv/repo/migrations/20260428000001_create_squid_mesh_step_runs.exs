defmodule SquidMesh.Repo.Migrations.CreateSquidMeshStepRuns do
  use Ecto.Migration

  def change do
    create table(:squid_mesh_step_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:squid_mesh_runs, type: :binary_id, on_delete: :delete_all), null: false
      add :step, :string, null: false
      add :status, :string, null: false
      add :input, :map, null: false, default: %{}
      add :output, :map
      add :last_error, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:squid_mesh_step_runs, [:run_id])
    create index(:squid_mesh_step_runs, [:status])
    create unique_index(:squid_mesh_step_runs, [:run_id, :step])
  end
end
