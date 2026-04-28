defmodule Mix.Tasks.Example.Smoke do
  @moduledoc """
  Runs the example host app smoke test.
  """

  use Mix.Task

  @shortdoc "Runs the example host app smoke test"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    MinimalHostApp.Smoke.run!()
  end
end
