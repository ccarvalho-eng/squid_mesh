defmodule MinimalHostApp.Steps.RecordDigestDelivery do
  @moduledoc """
  Example step that records digest delivery metadata.
  """

  use Jido.Action,
    name: "record_digest_delivery",
    description: "Records digest delivery metadata",
    schema: [
      channel: [type: :string, required: true],
      digest_date: [type: :string, required: true]
    ]

  @impl true
  @spec run(map(), map()) :: {:ok, map()}
  def run(%{channel: channel, digest_date: digest_date}, _context) do
    {:ok,
     %{
       digest_delivery: %{
         channel: channel,
         digest_date: digest_date,
         delivered_at: DateTime.utc_now() |> DateTime.to_iso8601()
       }
     }}
  end
end
