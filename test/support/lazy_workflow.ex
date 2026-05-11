defmodule SquidMesh.TestSupport.LazyWorkflow do
  @moduledoc false

  use SquidMesh.Workflow

  workflow do
    trigger :manual do
      manual()

      payload do
        field :account_id, :string
      end
    end

    step :load_invoice, SquidMesh.TestSupport.LazyWorkflow.LoadInvoice, retry: [max_attempts: 1]
    transition :load_invoice, on: :ok, to: :complete
  end
end
