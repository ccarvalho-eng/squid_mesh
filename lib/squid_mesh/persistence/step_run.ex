defmodule SquidMesh.Persistence.StepRun do
  @moduledoc """
  Persisted state for one workflow step execution.

  A step run belongs to a workflow run and tracks the step input, output, and
  latest error payload for that step within the durable execution history.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SquidMesh.Persistence.Run
  alias SquidMesh.Persistence.StepAttempt

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type status :: String.t()

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          run_id: Ecto.UUID.t() | nil,
          run: Run.t() | Ecto.Association.NotLoaded.t() | nil,
          step: String.t() | nil,
          status: status() | nil,
          input: map() | nil,
          output: map() | nil,
          last_error: map() | nil,
          attempts: [StepAttempt.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @required_fields ~w(run_id step status)a
  @optional_fields ~w(input output last_error)a

  schema "squid_mesh_step_runs" do
    belongs_to(:run, Run)
    field(:step, :string)
    field(:status, :string)
    field(:input, :map, default: %{})
    field(:output, :map)
    field(:last_error, :map)
    has_many(:attempts, StepAttempt)

    timestamps()
  end

  @doc """
  Builds a changeset for persisted step run state.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(step_run, attrs) do
    step_run
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:run_id)
  end
end
