defmodule OtelMetricExporter.MixProject do
  use Mix.Project

  def project do
    [
      app: :otel_metric_exporter,
      name: "OTel Metric Exporter",
      description: "An unofficial OTel-compatible metric exporter",
      version: "0.3.4",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      source_url: "https://github.com/electric-sql/elixir-otel-metric-exporter",
      homepage_url: "https://github.com/electric-sql/elixir-otel-metric-exporter",
      deps: deps(),
      docs: &docs/0,
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => "https://github.com/electric-sql/elixir-otel-metric-exporter"},
        files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {OtelMetricExporter.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:protobuf, "~> 0.13.0"},
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:finch, "~> 0.19"},
      {:retry, "~> 0.19"},
      {:bypass, "~> 2.1", only: [:test]},
      {:ex_doc, ">= 0.0.0", only: [:dev], runtime: false}
    ]
  end

  defp docs do
    [
      main: "OtelMetricExporter",
      api_reference: false
    ]
  end
end
