defmodule MinimalHostApp.Steps.ReleaseInventory do
  @moduledoc """
  Releases inventory reserved by the saga checkout workflow.

  This compensation callback receives the completed `:reserve_inventory` step
  output and records the domain-level rollback result.
  """

  use Jido.Action,
    name: "release_inventory",
    description: "Releases a previous inventory reservation",
    schema: []

  @impl true
  def run(%{step: %{output: %{inventory_reservation: reservation}}}, _context) do
    {:ok, %{released_inventory: Map.put(reservation, :status, "released")}}
  end
end
