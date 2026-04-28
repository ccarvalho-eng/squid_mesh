defmodule Mix.Tasks.Example.Resilience do
  @moduledoc """
  Runs the example host app restart resilience verification.
  """

  use Mix.Task

  @shortdoc "Runs the example host app restart resilience verification"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    MinimalHostApp.Verification.RestartResilience.run!()
  end
end
