defmodule MinimalHostApp.Steps.CheckGatewayStatus do
  @moduledoc """
  Example step that checks payment gateway state.
  """

  @spec run(map(), map()) :: {:ok, map()}
  def run(input, _context) do
    {:ok, %{gateway_status: :retry_required, input: input}}
  end
end
