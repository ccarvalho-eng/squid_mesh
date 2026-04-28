defmodule SquidMeshTest do
  use ExUnit.Case

  test "configures an application supervisor" do
    assert Application.spec(:squid_mesh, :mod) == {SquidMesh.Application, []}
  end

  test "loads the public entrypoint module" do
    assert Code.ensure_loaded?(SquidMesh)
  end

  describe "config/1" do
    test "returns the validated host app contract with defaults" do
      assert {:ok, config} = SquidMesh.config(repo: SquidMeshTest.Repo)

      assert config.repo == SquidMeshTest.Repo
      assert config.execution_name == Oban
      assert config.execution_queue == :squid_mesh
    end

    test "allows host applications to override execution settings" do
      overrides = [repo: SquidMeshTest.Repo, execution: [name: MyApp.Oban, queue: :workflows]]

      assert {:ok, config} = SquidMesh.config(overrides)

      assert config.execution_name == MyApp.Oban
      assert config.execution_queue == :workflows
    end

    test "reports missing required configuration keys" do
      assert {:error, {:missing_config, [:repo]}} = SquidMesh.config()
    end
  end
end
