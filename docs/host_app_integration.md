# Host App Integration

Squid Mesh is configured once by the host application and then consumed through
application code and application-facing APIs.

This document defines the initial integration contract for:

- Phoenix applications
- OTP applications with an existing `Repo`
- existing installations that already run background jobs

## Author Experience

Workflow authors and application developers should work with:

- declarative workflow modules
- Squid Mesh public API calls
- product-level concepts such as runs, steps, retries, cancellations, and replay

They should not need to understand:

- persistence internals
- supervision structure
- execution recovery mechanics
- job scheduling details

## Required Host App Configuration

The host application configures Squid Mesh under the `:squid_mesh` application:

```elixir
config :squid_mesh,
  repo: MyApp.Repo,
  execution: [
    name: Oban,
    queue: :squid_mesh
  ]
```

Required keys:

- `:repo` - the Ecto repo Squid Mesh uses for persisted runtime state

Optional keys:

- `:execution` - execution system settings
- `:execution[:name]` - the background job system name to target
- `:execution[:queue]` - queue used for Squid Mesh jobs, defaults to `:squid_mesh`

## Existing Application Path

For an existing Phoenix or OTP application:

1. Add the `:squid_mesh` dependency.
2. Configure `:repo` to point at the app's existing repo.
3. Configure `:execution` to point at the app's existing background job setup.
4. Expose Squid Mesh capabilities through the host application's own contexts,
   services, controllers, or internal APIs.

The host application remains responsible for:

- database setup and migrations
- background job infrastructure lifecycle
- any HTTP or internal API endpoints exposed to end users

## Standalone Development Path

For local development and examples, a minimal host app can provide:

- a local Postgres-backed repo
- a local background job setup
- direct application code calls into Squid Mesh

This path exists to make development and examples easy. It does not change the
integration contract used by existing applications.

## Validation API

Host applications can validate the contract directly:

```elixir
{:ok, config} = SquidMesh.config()
```

Or raise on missing required keys:

```elixir
config = SquidMesh.config!()
```

This keeps installer-facing concerns concentrated in one place while the rest
of the library can build on a stable runtime boundary.
