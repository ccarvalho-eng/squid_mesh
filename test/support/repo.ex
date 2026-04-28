defmodule SquidMesh.Test.Repo do
  @moduledoc false

  use Ecto.Repo, otp_app: :squid_mesh, adapter: Ecto.Adapters.Postgres
end
