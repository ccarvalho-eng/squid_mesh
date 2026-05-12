defmodule MinimalHostApp.Steps.CapturePayment do
  @moduledoc """
  Fails payment capture for the saga checkout smoke path.

  The deliberate failure lets the host app example verify retry exhaustion,
  terminal failure persistence, compensation dispatch, and rollback inspection.
  """

  use Jido.Action,
    name: "capture_payment",
    description: "Captures an authorized payment",
    schema: []

  @impl true
  def run(_params, _context) do
    {:error, %{message: "payment capture declined", code: "capture_declined"}}
  end
end
