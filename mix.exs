defmodule SquidMesh.MixProject do
  use Mix.Project

  def project do
    [
      app: :squid_mesh,
      version: "0.1.0-alpha.1",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: description(),
      source_url: "https://github.com/ccarvalho-eng/squid_mesh",
      homepage_url: "https://github.com/ccarvalho-eng/squid_mesh",
      docs: docs(),
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
      name: "squid_mesh",
      maintainers: ["Cristiano Carvalho"],
      licenses: ["Apache-2.0"],
      files:
        ~w(lib priv docs .formatter.exs mix.exs mix.lock README* CHANGELOG* LICENSE* CONTRIBUTING* CODE_OF_CONDUCT*),
      links: %{"GitHub" => "https://github.com/ccarvalho-eng/squid_mesh"}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "docs/architecture.md",
        "docs/compatibility.md",
        "docs/tool_adapters.md",
        "docs/observability.md",
        "docs/workflow_authoring.md",
        "docs/host_app_integration.md",
        "docs/operations.md",
        "docs/production_readiness.md",
        "docs/adr/index.md",
        "docs/adr/0001-runtime-boundaries.md",
        "docs/adr/0002-workflow-payload-contract.md",
        "docs/adr/0003-recovery-boundary.md",
        "docs/adr/template.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "CODE_OF_CONDUCT.md",
        "LICENSE"
      ]
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
      {:postgrex, "~> 0.20", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
