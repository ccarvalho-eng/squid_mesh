defmodule MinimalHostApp.Steps.LoadAccount do
  @moduledoc """
  Example step that loads account context for dependency-based workflows.
  """

  use Jido.Action,
    name: "load_account",
    description: "Loads account context",
    schema: [
      account_id: [type: :string, required: true]
    ]

  @impl true
  @spec run(map(), map()) :: {:ok, map()}
  def run(%{account_id: account_id}, _context) do
    {:ok,
     %{
       account: %{id: account_id, tier: "standard"}
     }}
  end
end
