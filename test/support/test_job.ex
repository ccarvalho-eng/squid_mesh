defmodule SquidMesh.Test.Job do
  @moduledoc false

  defstruct [:id, :worker, :queue, :args, :inserted_at, :scheduled_at, :meta]
end
