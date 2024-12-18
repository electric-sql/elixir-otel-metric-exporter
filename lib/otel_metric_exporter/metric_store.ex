defmodule OtelMetricExporter.MetricStore do
  use GenServer

  require Logger

  alias OtelMetricExporter.Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceRequest

  alias OtelMetricExporter.Opentelemetry.Proto.Metrics.V1.{
    ResourceMetrics,
    ScopeMetrics,
    Metric,
    NumberDataPoint,
    HistogramDataPoint,
    Sum,
    Gauge,
    Histogram
  }

  alias OtelMetricExporter.Opentelemetry.Proto.Common.V1.{
    InstrumentationScope,
    AnyValue
  }

  defmodule State do
    @moduledoc false
    defstruct [:config, :finch_pool, metrics: %{}]

    @type t :: %__MODULE__{
            config: map(),
            finch_pool: module(),
            metrics: %{
              optional(String.t()) => %{
                metric: Telemetry.Metrics.t(),
                type: :counter | :sum | :last_value | :distribution,
                values: %{
                  optional(map()) => number() | [number()]
                },
                buckets: [number()] | nil
              }
            }
          }
  end

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(config) do
    metrics = Map.get(config, :metrics, [])
    finch_pool = Map.get(config, :finch_pool, Finch)
    Process.send_after(self(), :export, config.export_period)

    {:ok, %State{config: config, finch_pool: finch_pool, metrics: init_metrics(metrics)}}
  end

  @impl true
  def handle_cast({:record_metric, name, value, tags}, state) do
    {:noreply, record_metric(name, value, tags, nil, state)}
  end

  def handle_cast({:record_metric, name, value, tags, buckets}, state) do
    {:noreply, record_metric(name, value, tags, buckets, state)}
  end

  defp record_metric(name, value, tags, buckets, state) do
    metric_def = get_or_init_metric(name, state, buckets)
    updated_values = update_metric_values(metric_def, value, tags)

    put_in(state.metrics[name], %{metric_def | values: updated_values})
  end

  defp get_or_init_metric(name, state, buckets) do
    case state.metrics[name] do
      nil ->
        # Infer type from name
        type =
          cond do
            String.ends_with?(to_string(name), ".counter") -> :counter
            String.ends_with?(to_string(name), ".sum") -> :sum
            String.ends_with?(to_string(name), ".last_value") -> :last_value
            String.ends_with?(to_string(name), ".distribution") -> :distribution
            # Default to counter if unknown
            true -> :counter
          end

        %{
          type: type,
          values: %{},
          buckets: buckets || state.config.default_buckets
        }

      existing ->
        existing
    end
  end

  defp update_metric_values(%{type: :counter} = metric, value, tags) do
    Map.update(metric.values, tags, value, &(&1 + value))
  end

  defp update_metric_values(%{type: :sum} = metric, value, tags) do
    Map.update(metric.values, tags, value, &(&1 + value))
  end

  defp update_metric_values(%{type: :last_value} = metric, value, tags) do
    Map.put(metric.values, tags, value)
  end

  defp update_metric_values(%{type: :distribution} = metric, value, tags) do
    Map.update(metric.values, tags, [value], &(&1 ++ [value]))
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    {:reply, state.metrics, state}
  end

  def get_metrics do
    GenServer.call(__MODULE__, :get_metrics)
  end

  @impl true
  def handle_info(:export, state) do
    Process.send_after(self(), :export, state.config.export_period)

    case export_metrics(state) do
      :ok ->
        {:noreply, %{state | metrics: %{}}}

      {:error, reason} ->
        Logger.error("Failed to export metrics: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp export_metrics(%{metrics: metrics}) when map_size(metrics) == 0 do
    :ok
  end

  defp export_metrics(state) do
    metrics = Map.values(state.metrics)

    request = %ExportMetricsServiceRequest{
      resource_metrics: [
        %ResourceMetrics{
          scope_metrics: [
            %ScopeMetrics{
              scope: %InstrumentationScope{
                name: "otel_metric_exporter",
                version: "1.0.0"
              },
              metrics: Enum.map(metrics, &convert_metric/1)
            }
          ]
        }
      ]
    }

    body = ExportMetricsServiceRequest.encode(request)

    headers = [
      {"content-type", "application/x-protobuf"},
      {"accept", "application/x-protobuf"}
      | Map.to_list(state.config.otlp_headers)
    ]

    case Finch.build(:post, state.config.otlp_endpoint <> "/v1/metrics", headers, body)
         |> Finch.request(state.finch_pool) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, response} ->
        {:error, {:unexpected_status, response}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp init_metrics(metrics) do
    metrics
    |> Enum.map(&init_metric/1)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp init_metric(metric) do
    type =
      case metric do
        %Telemetry.Metrics.Counter{} ->
          :counter

        %Telemetry.Metrics.Sum{} ->
          :sum

        %Telemetry.Metrics.LastValue{} ->
          :last_value

        %Telemetry.Metrics.Distribution{} ->
          :distribution

        other ->
          Logger.warning(
            "Unsupported metric type #{inspect(other)}. Only counter, sum, last_value and distribution are supported"
          )

          nil
      end

    if type do
      buckets =
        if type == :distribution do
          get_in(metric.reporter_options, [:buckets])
        end

      name = metric.name |> Enum.map(&to_string/1) |> Enum.join(".")

      {name,
       %{
         metric: metric,
         type: type,
         values: %{},
         buckets: buckets
       }}
    end
  end

  defp convert_metric(%{type: :distribution, buckets: bounds, values: values}) do
    %Metric{
      name: "",
      description: "",
      unit: "",
      data:
        {:histogram,
         %Histogram{
           data_points:
             Enum.map(values, fn {tags, values} ->
               %HistogramDataPoint{
                 attributes: build_attributes(tags),
                 time_unix_nano: System.system_time(:nanosecond),
                 count: length(values),
                 sum: Enum.sum(values),
                 bucket_counts: count_buckets(values, bounds),
                 explicit_bounds: bounds
               }
             end),
           aggregation_temporality: :AGGREGATION_TEMPORALITY_CUMULATIVE
         }}
    }
  end

  defp convert_metric(%{type: :counter, values: values}) do
    %Metric{
      name: "",
      description: "",
      unit: "",
      data:
        {:sum,
         %Sum{
           data_points:
             Enum.map(values, fn {tags, value} ->
               %NumberDataPoint{
                 attributes: build_attributes(tags),
                 time_unix_nano: System.system_time(:nanosecond),
                 value: {:as_double, value}
               }
             end),
           is_monotonic: true,
           aggregation_temporality: :AGGREGATION_TEMPORALITY_CUMULATIVE
         }}
    }
  end

  defp convert_metric(%{type: :sum, values: values}) do
    %Metric{
      name: "",
      description: "",
      unit: "",
      data:
        {:sum,
         %Sum{
           data_points:
             Enum.map(values, fn {tags, value} ->
               %NumberDataPoint{
                 attributes: build_attributes(tags),
                 time_unix_nano: System.system_time(:nanosecond),
                 value: {:as_double, value}
               }
             end),
           is_monotonic: false,
           aggregation_temporality: :AGGREGATION_TEMPORALITY_CUMULATIVE
         }}
    }
  end

  defp convert_metric(%{type: :last_value, values: values}) do
    %Metric{
      name: "",
      description: "",
      unit: "",
      data:
        {:gauge,
         %Gauge{
           data_points:
             Enum.map(values, fn {tags, value} ->
               %NumberDataPoint{
                 attributes: build_attributes(tags),
                 time_unix_nano: System.system_time(:nanosecond),
                 value: {:as_double, value}
               }
             end)
         }}
    }
  end

  defp count_buckets(values, bounds) do
    # Initialize counts with zeros
    counts = List.duplicate(0, length(bounds) + 1)

    # Count values in each bucket
    values
    |> Enum.reduce(counts, fn value, counts ->
      bucket_index = find_bucket_index(value, bounds)
      List.update_at(counts, bucket_index, &(&1 + 1))
    end)
  end

  defp find_bucket_index(value, bounds) do
    case Enum.find_index(bounds, &(value <= &1)) do
      # Last bucket (infinity)
      nil -> length(bounds)
      index -> index
    end
  end

  defp build_attributes(tags) do
    tags
    |> Enum.map(fn {key, value} ->
      %{
        key: to_string(key),
        value: %AnyValue{value: {:string_value, to_string(value)}}
      }
    end)
  end
end
