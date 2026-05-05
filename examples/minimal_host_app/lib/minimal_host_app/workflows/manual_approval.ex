defmodule MinimalHostApp.Workflows.ManualApproval do
  @moduledoc """
  Example workflow that pauses until an operator explicitly resumes the run.
  """

  use SquidMesh.Workflow

  workflow do
    trigger :manual_approval do
      manual()

      payload do
        field(:account_id, :string)
      end
    end

    step(:wait_for_approval, :pause)

    step(:record_approval, MinimalHostApp.Steps.RecordApproval,
      input: [:account_id],
      output: :approval
    )

    transition(:wait_for_approval, on: :ok, to: :record_approval)
    transition(:record_approval, on: :ok, to: :complete)
  end
end
