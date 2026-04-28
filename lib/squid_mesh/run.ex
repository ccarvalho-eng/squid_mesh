defmodule SquidMesh.Run do
  @moduledoc """
  Public representation of a workflow run.

  This struct keeps the library-facing API focused on workflow concepts rather
  than exposing the underlying persistence schema directly.
  """

  @type status ::
          :pending | :running | :retrying | :failed | :completed | :cancelling | :cancelled

  @type t :: %__MODULE__{}

  defstruct [
    :id,
    :workflow,
    :status,
    :payload,
    :context,
    :current_step,
    :last_error,
    :replayed_from_run_id,
    :inserted_at,
    :updated_at
  ]
end
