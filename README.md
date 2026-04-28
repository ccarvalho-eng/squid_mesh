<div align="center">
  <img width="350" alt="logo" src="https://github.com/user-attachments/assets/22c973ae-5d03-4aaf-99c9-75640e985f1e" />

  <p><i>Durable workflow runtime for Elixir applications.</i></p>

  [![CI](https://github.com/ccarvalho-eng/squid_mesh/actions/workflows/ci.yml/badge.svg)](https://github.com/ccarvalho-eng/squid_mesh/actions/workflows/ci.yml)
  [![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
</div>

Squid Mesh is a library for defining and running durable workflows inside
Phoenix and OTP applications.

## Requirements

- an existing Elixir application
- an existing Ecto `Repo`
- Postgres for persisted runtime state
- an existing `Oban` setup for background execution

## Installation

For local development against a checkout, add Squid Mesh to your host
application's dependencies:

```elixir
defp deps do
  [
    {:squid_mesh, path: "../squid_mesh"}
  ]
end
```

## Configuration

Configure Squid Mesh under the `:squid_mesh` application:

```elixir
config :squid_mesh,
  repo: MyApp.Repo,
  execution: [
    name: Oban,
    queue: :squid_mesh
  ]
```

Current runtime API:

- `SquidMesh.start_run/3`
- `SquidMesh.inspect_run/2`
- `SquidMesh.list_runs/2`
- `SquidMesh.cancel_run/2`

## Current Example

```elixir
defmodule Content.Workflows.PostDailyDigest do
  use SquidMesh.Workflow

  workflow do
    input do
      field(:feed_url, :string)
      field(:discord_webhook_url, :string)
      field(:posted_on, :string)
    end

    step(:fetch_feed, Content.Steps.FetchRssFeed)
    step(:build_digest, Content.Steps.BuildDiscordDigest)
    step(:post_to_discord, Content.Steps.PostDiscordMessage)

    transition(:fetch_feed, on: :ok, to: :build_digest)
    transition(:build_digest, on: :ok, to: :post_to_discord)
    transition(:post_to_discord, on: :ok, to: :complete)

    retry(:fetch_feed, max_attempts: 3)
    retry(:post_to_discord, max_attempts: 5)
  end
end
```

## Call It From Your App Today

```elixir
defmodule Content.DailyDigestJob do
  def run do
    SquidMesh.start_run(Content.Workflows.PostDailyDigest, %{
      feed_url: "https://example.com/feed.xml",
      discord_webhook_url: System.fetch_env!("DISCORD_WEBHOOK_URL"),
      posted_on: Date.utc_today() |> Date.to_iso8601()
    })
  end

  def inspect_digest_run(run_id) do
    SquidMesh.inspect_run(run_id)
  end

  def list_active_digests do
    SquidMesh.list_runs(status: :running)
  end

  def cancel_digest_run(run_id) do
    SquidMesh.cancel_run(run_id)
  end
end
```

That workflow would typically be triggered by your application's own daily cron
job or scheduler.

## Illustrative End-State Example

The snippet below shows the intended runtime shape once replay and execution
issues are complete.

```elixir
config :squid_mesh,
  repo: MyApp.Repo,
  execution: [
    name: MyApp.Oban,
    queue: :daily_digests
  ]

defmodule Content.Workflows.PostDailyDigest do
  use SquidMesh.Workflow

  workflow do
    input do
      field(:feed_url, :string)
      field(:discord_webhook_url, :string)
      field(:posted_on, :string)
    end

    step(:fetch_feed, Content.Steps.FetchRssFeed)
    step(:filter_entries, Content.Steps.FilterEntriesForToday)
    step(:build_digest, Content.Steps.BuildDiscordDigest)
    step(:post_to_discord, Content.Steps.PostDiscordMessage)
    step(:record_delivery, Content.Steps.RecordDigestDelivery)

    transition(:fetch_feed, on: :ok, to: :filter_entries)
    transition(:filter_entries, on: :ok, to: :build_digest)
    transition(:build_digest, on: :ok, to: :post_to_discord)
    transition(:post_to_discord, on: :ok, to: :record_delivery)
    transition(:record_delivery, on: :ok, to: :complete)

    retry(:fetch_feed, max_attempts: 3)
    retry(:post_to_discord, max_attempts: 5)
  end
end

defmodule Content.Steps.FetchRssFeed do
  def run(input, context) do
    Content.Agents.FetchRssFeed.run(input, context)
  end
end

defmodule Content.Agents.FetchRssFeed do
  # Jido-backed agent or action module
  def run(%{feed_url: feed_url} = input, _context) do
    with {:ok, response} <- Req.get(feed_url),
         {:ok, entries} <- Content.Rss.parse_entries(response.body) do
      {:ok, Map.put(input, :entries, entries)}
    else
      {:error, reason} ->
        {:error, %{message: "failed to fetch RSS feed", reason: reason}}
    end
  end
end

defmodule Content.DigestRuns do
  def start_daily_digest(feed_url, webhook_url) do
    SquidMesh.start_run(Content.Workflows.PostDailyDigest, %{
      feed_url: feed_url,
      discord_webhook_url: webhook_url,
      posted_on: Date.utc_today() |> Date.to_iso8601()
    })
  end

  def inspect_run(run_id) do
    SquidMesh.inspect_run(run_id)
  end

  def list_recent_runs do
    SquidMesh.list_runs(workflow: Content.Workflows.PostDailyDigest, limit: 20)
  end

  def cancel_run(run_id) do
    SquidMesh.cancel_run(run_id)
  end

  def replay_run(run_id) do
    SquidMesh.replay_run(run_id)
  end
end

defmodule Content.DailyDigestJob do
  def run do
    Content.DigestRuns.start_daily_digest(
      "https://example.com/feed.xml",
      System.fetch_env!("DISCORD_WEBHOOK_URL")
    )
  end
end
```

Run lifecycle states currently include:

- `pending`
- `running`
- `retrying`
- `failed`
- `completed`
- `cancelling`
- `cancelled`

## Getting Started

- [Host app integration](docs/host_app_integration.md)
- [Example host app harness](examples/minimal_host_app/README.md)

Fast local smoke path:

```sh
cd examples/minimal_host_app
MIX_ENV=test mix example.smoke
```
