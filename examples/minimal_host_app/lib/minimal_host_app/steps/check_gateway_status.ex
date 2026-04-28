defmodule MinimalHostApp.Steps.CheckGatewayStatus do
  @moduledoc """
  Example step that checks payment gateway state.
  """

  use Jido.Action,
    name: "check_gateway_status",
    description: "Checks gateway state",
    schema: [
      invoice: [type: :map, required: true],
      gateway_url: [type: :string, required: true]
    ]

  @impl true
  @spec run(map(), map()) :: {:ok, map()} | {:error, map()}
  def run(%{invoice: invoice, gateway_url: gateway_url}, _context) do
    case SquidMesh.Tools.invoke(SquidMesh.Tools.HTTP, %{method: :get, url: gateway_url}) do
      {:ok, result} ->
        {:ok,
         %{
           gateway_check: %{
             status: result.payload.body,
             invoice_id: invoice.id,
             status_code: result.payload.status
           }
         }}

      {:error, error} ->
        {:error, SquidMesh.Tools.Error.to_map(error)}
    end
  end
end
