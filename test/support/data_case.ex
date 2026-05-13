defmodule SquidMesh.DataCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias SquidMesh.Test.Repo

      import ExUnit.Assertions
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import SquidMesh.DataCase
    end
  end

  def all_enqueued(_opts \\ []) do
    SquidMesh.Test.Executor.jobs()
  end

  def assert_enqueued(opts) do
    expected_args = Keyword.get(opts, :args, %{})

    if Enum.any?(all_enqueued(), &job_matches?(&1, expected_args)) do
      :ok
    else
      flunk("expected queued job with args #{inspect(expected_args)}")
    end
  end

  setup tags do
    SquidMesh.Test.Executor.reset!()

    pid = Sandbox.start_owner!(SquidMesh.Test.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  @spec errors_on(Ecto.Changeset.t()) :: map()
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp job_matches?(%{args: args}, expected_args) do
    Enum.all?(expected_args, fn {key, value} -> Map.get(args, to_string(key)) == value end)
  end
end
