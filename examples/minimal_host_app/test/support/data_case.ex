defmodule MinimalHostApp.DataCase do
  @moduledoc false

  use ExUnit.CaseTemplate
  use Oban.Testing, repo: MinimalHostApp.Repo

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias MinimalHostApp.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import MinimalHostApp.DataCase
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(MinimalHostApp.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
