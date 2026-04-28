defmodule MinimalHostApp.Repo do
  @moduledoc """
  Repo used by the example host application.
  """

  use Ecto.Repo,
    otp_app: :minimal_host_app,
    adapter: Ecto.Adapters.Postgres
end
