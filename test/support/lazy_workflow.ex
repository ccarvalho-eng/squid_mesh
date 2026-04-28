defmodule SquidMesh.TestSupport.LazyWorkflow do
  @moduledoc false

  use SquidMesh.Workflow

  workflow do
    input do
      field(:account_id, :string)
    end

    step(:load_invoice, SquidMesh.TestSupport.LazyWorkflow.LoadInvoice)
    transition(:load_invoice, on: :ok, to: :complete)
    retry(:load_invoice, max_attempts: 1)
  end
end
