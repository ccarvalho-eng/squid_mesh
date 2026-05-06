defmodule Mix.Tasks.SquidMesh.InstallTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @task "squid_mesh.install"

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "squid_mesh-install-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp_dir, "priv/repo/migrations"))

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      Mix.Task.reenable(@task)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "copies new migrations and skips ones already installed", %{tmp_dir: tmp_dir} do
    [existing_migration | _rest] = source_migrations()
    migration_name = migration_name(existing_migration)

    File.write!(
      Path.join(tmp_dir, "priv/repo/migrations/20260101000000_#{migration_name}"),
      "# existing migration\n"
    )

    output =
      File.cd!(tmp_dir, fn ->
        capture_io(fn ->
          Mix.Tasks.SquidMesh.Install.run([])
        end)
      end)

    installed_migrations = File.ls!(Path.join(tmp_dir, "priv/repo/migrations"))

    assert Enum.count(installed_migrations, &String.ends_with?(&1, migration_name)) == 1

    assert Enum.any?(
             installed_migrations,
             &String.ends_with?(&1, "add_manual_to_squid_mesh_step_runs.exs")
           )

    assert output =~ "skipping #{migration_name}"
    assert output =~ "add_manual_to_squid_mesh_step_runs.exs"
  end

  defp source_migrations do
    :squid_mesh
    |> Application.app_dir(["priv", "repo", "migrations"])
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".exs"))
    |> Enum.reject(&String.starts_with?(&1, "."))
    |> Enum.sort()
  end

  defp migration_name(filename) do
    filename
    |> String.split("_", parts: 2)
    |> List.last()
  end
end
