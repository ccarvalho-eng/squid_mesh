defmodule SquidMeshTest do
  use ExUnit.Case

  test "configures an application supervisor" do
    assert Application.spec(:squid_mesh, :mod) == {SquidMesh.Application, []}
  end

  test "loads the public entrypoint module" do
    assert Code.ensure_loaded?(SquidMesh)
  end
end
