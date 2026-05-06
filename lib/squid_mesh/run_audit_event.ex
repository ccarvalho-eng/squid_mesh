defmodule SquidMesh.RunAuditEvent do
  @moduledoc """
  Public representation of one durable human-in-the-loop workflow event.

  Audit events summarize when a run paused for manual intervention and when an
  operator later resumed, approved, or rejected it.
  """

  @type type :: :paused | :resumed | :approved | :rejected

  @type t :: %__MODULE__{}

  defstruct [
    :type,
    :step,
    :actor,
    :comment,
    :metadata,
    :at
  ]
end
