defmodule MinimalHostApp.Steps.PrepareNotification do
  @moduledoc """
  Example join step that waits for account and invoice context.
  """

  use Jido.Action,
    name: "prepare_notification",
    description: "Builds notification context once dependencies are ready",
    schema: [
      account: [type: :map, required: true],
      invoice: [type: :map, required: true]
    ]

  @impl true
  @spec run(map(), map()) :: {:ok, map()}
  def run(%{account: account, invoice: invoice}, _context) do
    {:ok,
     %{
       notification: %{
         channel: "email",
         account_id: account.id,
         invoice_id: invoice.id,
         account_tier: account.tier
       }
     }}
  end
end
