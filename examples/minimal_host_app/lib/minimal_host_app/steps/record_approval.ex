defmodule MinimalHostApp.Steps.RecordApproval do
  @moduledoc """
  Example step that records a manual approval decision after a paused gate.
  """

  use Jido.Action,
    name: "record_approval",
    description: "Records an approved manual review result",
    schema: [
      account_id: [type: :string, required: true]
    ]

  @impl true
  @spec run(map(), map()) :: {:ok, map()}
  def run(%{account_id: account_id}, _context) do
    {:ok,
     %{
       account_id: account_id,
       status: "approved"
     }}
  end
end
