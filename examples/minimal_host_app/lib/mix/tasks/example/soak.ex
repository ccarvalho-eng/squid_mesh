defmodule Mix.Tasks.Example.Soak do
  @moduledoc """
  Runs the example host app bounded soak and load verification.
  """

  use Mix.Task

  @shortdoc "Runs the example host app bounded soak and load verification"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    MinimalHostApp.Verification.Soak.run!()
  end
end
