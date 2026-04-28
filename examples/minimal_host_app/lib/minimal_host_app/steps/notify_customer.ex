defmodule MinimalHostApp.Steps.NotifyCustomer do
  @moduledoc """
  Example step that records customer notification intent.
  """

  @spec run(map(), map()) :: {:ok, map()}
  def run(input, _context) do
    {:ok, %{notification: :queued, input: input}}
  end
end
