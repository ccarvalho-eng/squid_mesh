defmodule MinimalHostApp.Steps.LoadInvoice do
  @moduledoc """
  Example step that loads invoice context for a recovery run.
  """

  @spec run(map(), map()) :: {:ok, map()}
  def run(input, _context) do
    {:ok, %{invoice: input}}
  end
end
