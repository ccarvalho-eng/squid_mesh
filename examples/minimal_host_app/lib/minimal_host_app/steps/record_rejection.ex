defmodule MinimalHostApp.Steps.RecordRejection do
  @moduledoc """
  Example step that records a manual rejection decision after review.
  """

  use Jido.Action,
    name: "record_rejection",
    description: "Records a rejected manual review result",
    schema: [
      account_id: [type: :string, required: true],
      approval: [type: :map, required: true]
    ]

  @impl true
  @spec run(map(), map()) :: {:ok, map()}
  def run(%{account_id: account_id, approval: approval}, _context) do
    {:ok,
     approval
     |> Map.put(:account_id, account_id)
     |> Map.put(:status, "rejected")}
  end
end
