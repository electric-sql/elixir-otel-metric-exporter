defmodule OtelMetricExporter do
  use Supervisor
  require Logger
  alias OtelMetricExporter.MetricStore
  alias Telemetry.Metrics

  @moduledoc """
  This is a `telemetry` exporter that collects specified metrics
  and then exports them to an OTel endpoint. It uses metric definitions
  from `:telemetry_metrics` library.

  Example usage:

      OtelMetricExporter.start_link(
        otlp_protocol: :http_protobuf,
        otlp_endpoint: otlp_endpoint,
        otlp_headers: headers,
        otlp_compression: :gzip,
        export_period: :timer.seconds(30),
        metrics: [
          Telemetry.Metrics.counter("plug.request.stop.duration"),
          Telemetry.Metrics.sum("plug.request.stop.duration"),
          Telemetry.Metrics.last_value("plug.request.stop.duration"),
          Telemetry.Metrics.distribution("plug.request.stop.duration",
            reporter_options: [buckets: [0, 10, 100, 1000]] # Optional histogram buckets.
          ),
        ]
      )

  Default histogram buckets are `#{inspect(MetricStore.default_buckets())}`

  See all available options in `start_link/2` documentation. Options provided to the `start_link/2`
  function will be merged with the options provided via `config :otel_metric_exporter` configuraiton.
  """

  @type protocol :: :http_protobuf | :http_json
  @type compression :: :gzip | nil

  @supported_metrics [
    Metrics.Counter,
    Metrics.Sum,
    Metrics.LastValue,
    Metrics.Distribution
  ]

  @options_schema NimbleOptions.new!(
                    metrics: [
                      type: {:list, {:or, for(x <- @supported_metrics, do: {:struct, x})}},
                      type_spec: quote(do: list(Metrics.t())),
                      required: true,
                      doc: "List of telemetry metrics to track."
                    ],
                    otlp_endpoint: [
                      type: :string,
                      required: true,
                      subsection: "OTLP transport",
                      doc: "Endpoint to send metrics to."
                    ],
                    otlp_protocol: [
                      type: {:in, [:http_protobuf]},
                      type_spec: quote(do: protocol()),
                      default: :http_protobuf,
                      subsection: "OTLP transport",
                      doc:
                        "Protocol to use for OTLP export. Currently only :http_protobuf and :http_json are supported."
                    ],
                    otlp_headers: [
                      type: {:map, :string, :string},
                      default: %{},
                      subsection: "OTLP transport",
                      doc: "Headers to send with OTLP requests."
                    ],
                    otlp_compression: [
                      type: {:in, [:gzip, nil]},
                      default: :gzip,
                      type_spec: quote(do: compression()),
                      subsection: "OTLP transport",
                      doc:
                        "Compression to use for OTLP requests. Allowed values are `:gzip` and `nil`."
                    ],
                    resource: [
                      type: :map,
                      default: %{},
                      doc: "Resource attributes to send with metrics."
                    ],
                    export_period: [
                      type: :pos_integer,
                      default: :timer.minutes(1),
                      doc: "Period in milliseconds between metric exports."
                    ],
                    name: [
                      type: :atom,
                      default: :otel_metric_exporter,
                      doc: "If you require multiple exporters, give each exporter a unique name."
                    ]
                  )

  @type option() :: unquote(NimbleOptions.option_typespec(@options_schema))

  @doc """
  Start the exporter. It maintains some pieces of global state: ets table and a `:persistent_term` key.
  This means that only one exporter instance can be started at a time.

  ## Options

  Options can be provided directly or specified in the `config :otel_metric_exporter` configuration. It's recommended
  to configure global options in `:otel_metric_exporter` config, and specify metrics where you add this module to the
  supervision tree.

  #{NimbleOptions.docs(@options_schema)}
  """
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts) do
    opts = Keyword.merge(Application.get_all_env(:otel_metric_exporter), opts)

    with {:ok, validated} <- NimbleOptions.validate(opts, @options_schema) do
      Supervisor.start_link(__MODULE__, Map.new(validated))
    end
  end

  @impl true
  def init(config) do
    :ok = setup_telemetry_handlers(config)

    children = [{MetricStore, config}]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp setup_telemetry_handlers(config) do
    handlers =
      config.metrics
      |> Enum.group_by(& &1.event_name)
      |> Enum.map(fn {event_name, metrics} ->
        handler_id = {__MODULE__, event_name}

        :telemetry.attach(
          handler_id,
          event_name,
          &__MODULE__.handle_metric/4,
          %{metrics: metrics, name: config.name}
        )

        handler_id
      end)

    # Store handler IDs in the process dictionary for cleanup
    Process.put(:"$otel_metric_handlers", handlers)

    :ok
  end

  @doc false
  def handle_metric(_event_name, measurements, metadata, %{metrics: metrics, name: name}) do
    for metric <- metrics do
      if is_nil(metric.keep) || metric.keep.(metadata) do
        value = extract_measurement(metric, measurements, metadata)
        tags = extract_tags(metric, metadata)

        metric_name = "#{Enum.join(metric.name, ".")}"
        MetricStore.write_metric(name, metric, metric_name, value, tags)
      end
    end
  end

  defp extract_measurement(metric, measurements, metadata) do
    case metric.measurement do
      fun when is_function(fun, 1) -> fun.(measurements)
      fun when is_function(fun, 2) -> fun.(measurements, metadata)
      key -> Map.get(measurements, key)
    end
  end

  defp extract_tags(metric, metadata) do
    metadata
    |> metric.tag_values.()
    |> Map.take(metric.tags)
  end
end
