defmodule SquidMesh.Tools.Adapter do
  @moduledoc """
  Behaviour for Squid Mesh tool adapters.

  Adapters receive a request map and a workflow context map, then return either
  a normalized tool result or a normalized tool error.
  """

  alias SquidMesh.Tools.Error
  alias SquidMesh.Tools.Result

  @type request :: map()
  @type context :: map()

  @callback invoke(request(), context(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
end
