defmodule SquidMesh.Persistence.StepAttempt do
  @moduledoc """
  Persisted attempt state for a step run.

  Step attempts capture retry history independently from the latest step state
  so the runtime can record how many times a step was attempted and what error
  payload was produced for each attempt.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SquidMesh.Persistence.StepRun

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type status :: String.t()

  @type t :: %__MODULE__{}

  @required_fields ~w(step_run_id attempt_number status)a
  @optional_fields ~w(error)a

  schema "squid_mesh_step_attempts" do
    belongs_to(:step_run, StepRun)
    field(:attempt_number, :integer)
    field(:status, :string)
    field(:error, :map)

    timestamps()
  end

  @doc """
  Builds a changeset for persisted step attempt state.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(step_attempt, attrs) do
    step_attempt
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:attempt_number, greater_than: 0)
    |> foreign_key_constraint(:step_run_id)
  end
end
