defmodule SquidMesh.MixProject do
  use Mix.Project

  def project do
    [
      app: :squid_mesh,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {SquidMesh.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp description do
    "Workflow automation platform for Elixir applications."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/ccarvalho-eng/squid_mesh"}
    ]
  end

  defp deps do
    [
      {:ecto_sql, "~> 3.13"},
      {:bypass, "~> 2.1", only: :test},
      {:jason, "~> 1.4"},
      {:jido, "~> 2.0"},
      {:oban, "~> 2.21"},
      {:req, "~> 0.5"},
      {:postgrex, "~> 0.20", only: :test}
    ]
  end
end
