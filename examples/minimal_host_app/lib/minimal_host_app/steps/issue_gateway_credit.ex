defmodule MinimalHostApp.Steps.IssueGatewayCredit do
  @moduledoc """
  Example compensation step for a failed gateway recovery path.
  """

  use Jido.Action,
    name: "issue_gateway_credit",
    description: "Issues a credit after gateway recovery cannot continue",
    schema: [
      account_id: [type: :string, required: true],
      invoice: [type: :map, required: true]
    ]

  @impl true
  @spec run(map(), map()) :: {:ok, map()}
  def run(%{account_id: account_id, invoice: invoice}, _context) do
    {:ok,
     %{
       compensation: %{
         account_id: account_id,
         invoice_id: invoice.id,
         status: "credit_issued"
       }
     }}
  end
end
