defmodule SquidMesh.Repo.Migrations.CreateSquidMeshStepAttempts do
  use Ecto.Migration

  def change do
    create table(:squid_mesh_step_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :step_run_id, references(:squid_mesh_step_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :attempt_number, :integer, null: false
      add :status, :string, null: false
      add :error, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:squid_mesh_step_attempts, [:step_run_id])
    create unique_index(:squid_mesh_step_attempts, [:step_run_id, :attempt_number])
  end
end
