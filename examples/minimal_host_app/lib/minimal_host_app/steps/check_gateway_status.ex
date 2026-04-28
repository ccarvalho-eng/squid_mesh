defmodule MinimalHostApp.Steps.CheckGatewayStatus do
  @moduledoc """
  Example step that checks payment gateway state.
  """

  use Jido.Action,
    name: "check_gateway_status",
    description: "Checks gateway state",
    schema: [
      invoice: [type: :map, required: true]
    ]

  @impl true
  @spec run(map(), map()) :: {:ok, map()}
  def run(%{invoice: invoice}, _context) do
    {:ok,
     %{
       gateway_check: %{status: "retry_required", invoice_id: invoice.id}
     }}
  end
end
