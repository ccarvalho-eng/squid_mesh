defmodule MinimalHostApp.Steps.NotifyCustomer do
  @moduledoc """
  Example step that records customer notification intent.
  """

  use Jido.Action,
    name: "notify_customer",
    description: "Records notification intent",
    schema: [
      invoice: [type: :map, required: true],
      gateway_check: [type: :map, required: true]
    ]

  @impl true
  @spec run(map(), map()) :: {:ok, map()}
  def run(%{invoice: invoice, gateway_check: gateway_check}, _context) do
    {:ok,
     %{
       notification: %{
         channel: "email",
         invoice_id: invoice.id,
         gateway_status: gateway_check.status
       }
     }}
  end
end
