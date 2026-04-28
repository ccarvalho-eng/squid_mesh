defmodule MinimalHostApp.Workflows.DailyDigest do
  @moduledoc """
  Example cron-triggered workflow for the host app.
  """

  use SquidMesh.Workflow

  workflow do
    trigger :daily_digest do
      cron("@reboot", timezone: "Etc/UTC")

      payload do
        field(:channel, :string, default: "ops")
        field(:digest_date, :string, default: {:today, :iso8601})
      end
    end

    step(:announce_digest, :log, message: "posting daily digest")
    step(:record_digest_delivery, MinimalHostApp.Steps.RecordDigestDelivery)

    transition(:announce_digest, on: :ok, to: :record_digest_delivery)
    transition(:record_digest_delivery, on: :ok, to: :complete)
  end
end
