defmodule Mix.Tasks.SquidMesh.Install do
  @moduledoc """
  Installs Squid Mesh by copying its migrations into the host application.

  ## Usage

      $ mix squid_mesh.install

  This task copies Squid Mesh-owned migrations into `priv/repo/migrations` so
  the host application can run them through its normal Ecto migration flow.

  `Oban` migrations are intentionally not copied. Squid Mesh assumes the host
  application already manages its own `oban_jobs` table.
  """

  @shortdoc "Installs Squid Mesh migrations into the host application"

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    source_dir = Application.app_dir(:squid_mesh, ["priv", "repo", "migrations"])
    dest_dir = Path.join(["priv", "repo", "migrations"])

    unless File.dir?(source_dir) do
      Mix.raise("Could not find Squid Mesh migrations directory at #{source_dir}")
    end

    unless File.dir?(dest_dir) do
      Mix.raise("""
      Could not find migrations directory at #{dest_dir}.
      Please ensure your application has an Ecto repository set up.
      """)
    end

    base_timestamp = timestamp()

    source_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".exs"))
    |> Enum.reject(&String.starts_with?(&1, "."))
    |> Enum.sort()
    |> Enum.with_index()
    |> Enum.each(fn {filename, index} ->
      copy_migration(filename, source_dir, dest_dir, base_timestamp, index)
    end)

    Mix.shell().info("""

    Squid Mesh migrations have been installed!

    Next steps:
      1. Run `mix ecto.migrate` to apply the migrations
      2. Configure Squid Mesh in your config:

          config :squid_mesh,
            repo: YourApp.Repo,
            execution: [name: Oban, queue: :squid_mesh]
    """)
  end

  defp copy_migration(filename, source_dir, dest_dir, base_timestamp, index) do
    migration_name =
      filename
      |> String.split("_", parts: 2)
      |> List.last()

    existing_migration =
      dest_dir
      |> File.ls!()
      |> Enum.find(fn file -> String.ends_with?(file, migration_name) end)

    if existing_migration do
      Mix.shell().info("* skipping #{migration_name} (already exists as #{existing_migration})")
    else
      migration_timestamp = add_seconds_to_timestamp(base_timestamp, index)
      new_filename = "#{migration_timestamp}_#{migration_name}"

      File.cp!(Path.join(source_dir, filename), Path.join(dest_dir, new_filename))
      Mix.shell().info("* copying #{new_filename}")
    end
  end

  defp add_seconds_to_timestamp(timestamp, seconds) do
    <<year::binary-4, month::binary-2, day::binary-2, hour::binary-2, minute::binary-2,
      second::binary-2>> = timestamp

    base_datetime =
      NaiveDateTime.new!(
        String.to_integer(year),
        String.to_integer(month),
        String.to_integer(day),
        String.to_integer(hour),
        String.to_integer(minute),
        String.to_integer(second)
      )

    new_datetime = NaiveDateTime.add(base_datetime, seconds, :second)

    "#{new_datetime.year |> Integer.to_string() |> String.pad_leading(4, "0")}#{new_datetime.month |> Integer.to_string() |> String.pad_leading(2, "0")}#{new_datetime.day |> Integer.to_string() |> String.pad_leading(2, "0")}#{new_datetime.hour |> Integer.to_string() |> String.pad_leading(2, "0")}#{new_datetime.minute |> Integer.to_string() |> String.pad_leading(2, "0")}#{new_datetime.second |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp timestamp do
    {{year, month, day}, {hour, minute, second}} = :calendar.universal_time()
    "#{year}#{pad(month)}#{pad(day)}#{pad(hour)}#{pad(minute)}#{pad(second)}"
  end

  defp pad(value) when value < 10, do: "0#{value}"
  defp pad(value), do: Integer.to_string(value)
end
