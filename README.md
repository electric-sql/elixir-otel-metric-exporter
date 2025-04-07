# OtelMetricExporter

This is an **unofficial** OTel-compatible `:telemetry` exporter that collects specified metrics
and then exports them to an OTel endpoint. It uses metric definitions
from `:telemetry_metrics` library and does not currently support `Summary` metric type.

This diverges from the official [OTel API requirements](https://opentelemetry.io/docs/specs/otel/metrics/api/) for metrics
in favour of reusing existing metric definitions from `:telemetry_metrics` library. Consequently, it
does not integrate with `:opentelemetry_api` library and the metrics won't have Exemplars with span/trace names
associated.

Of OTel metric types, this currently doesn't support `ExponentialHistogram` and `Summary` metric types.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `otel_metric_exporter` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:otel_metric_exporter, "~> 0.3.4"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/otel_metric_exporter>.
