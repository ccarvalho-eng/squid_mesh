defmodule MinimalHostApp.Steps.VoidPaymentAuthorization do
  @moduledoc """
  Voids a payment authorization created by the saga checkout workflow.

  This compensation callback demonstrates a business-level inverse operation
  rather than a same-step fallback.
  """

  use Jido.Action,
    name: "void_payment_authorization",
    description: "Voids a previous payment authorization",
    schema: []

  @impl true
  def run(%{step: %{output: %{payment_authorization: authorization}}}, _context) do
    {:ok, %{voided_payment_authorization: Map.put(authorization, :status, "voided")}}
  end
end
