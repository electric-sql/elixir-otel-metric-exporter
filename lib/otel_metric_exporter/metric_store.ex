defmodule OtelMetricExporter.MetricStore do
  @moduledoc false

  use GenServer

  require Logger

  alias Telemetry.Metrics
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
    AnyValue,
    KeyValue,
    KeyValueList,
    ArrayValue
  }

  alias OtelMetricExporter.Opentelemetry.Proto.Resource.V1.Resource

  @default_buckets [0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000]

  defmodule State do
    @moduledoc false
    defstruct [:config, :finch_pool, :metrics, :metrics_table, :last_export, :generations_table]

    @type t :: %__MODULE__{
            config: map(),
            finch_pool: module(),
            metrics: list(),
            metrics_table: atom(),
            generations_table: :ets.tid(),
            last_export: nil | DateTime.t()
          }
  end

  @doc false
  def default_buckets, do: @default_buckets

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: config.name)
  end

  def get_metrics(metrics_table, generation \\ nil) do
    generation = generation || :persistent_term.get(generation_key(metrics_table))

    :ets.match_object(metrics_table, {{generation, :_, :_, :_, :_}, :_, :_})
    |> Enum.reduce(%{}, fn
      {{_, name, :distribution, tags, bucket}, count, sum}, acc ->
        Map.update(
          acc,
          {:distribution, name},
          %{tags => %{bucket => {count, sum}}},
          fn all_tags ->
            Map.update(all_tags, tags, %{bucket => {count, sum}}, fn all_buckets ->
              Map.put(all_buckets, bucket, {count, sum})
            end)
          end
        )

      {{_, name, type, tags, _}, value, _}, acc ->
        Map.update(acc, {type, name}, %{tags => value}, fn all_tags ->
          Map.put(all_tags, tags, value)
        end)
    end)
  end

  def export_sync(name) do
    GenServer.call(name, :export_sync)
  end

  defp metric_type(%Metrics.Counter{}), do: :counter
  defp metric_type(%Metrics.Sum{}), do: :sum
  defp metric_type(%Metrics.LastValue{}), do: :last_value
  defp metric_type(%Metrics.Distribution{}), do: :distribution

  def write_metric(metrics_table, metric, value, tags),
    do: write_metric(metrics_table, metric, Enum.join(metric.name, "."), value, tags)

  def write_metric(metrics_table, %Metrics.Counter{} = metric, string_name, _, tags) do
    generation = :persistent_term.get(generation_key(metrics_table))
    ets_key = {generation, string_name, metric_type(metric), tags, nil}

    :ets.update_counter(metrics_table, ets_key, 1, {ets_key, 0, nil})
  end

  def write_metric(metrics_table, %Metrics.Sum{} = metric, string_name, value, tags) do
    generation = :persistent_term.get(generation_key(metrics_table))
    ets_key = {generation, string_name, metric_type(metric), tags, nil}

    :ets.update_counter(metrics_table, ets_key, value, {ets_key, 0, nil})
  end

  def write_metric(metrics_table, %Metrics.LastValue{} = metric, string_name, value, tags) do
    generation = :persistent_term.get(generation_key(metrics_table))
    ets_key = {generation, string_name, metric_type(metric), tags, nil}
    :ets.update_element(metrics_table, ets_key, {2, value}, {ets_key, value, nil})
  end

  def write_metric(metrics_table, %Metrics.Distribution{} = metric, string_name, value, tags) do
    bucket = find_bucket(metric, value)
    generation = :persistent_term.get(generation_key(metrics_table))
    ets_key = {generation, string_name, metric_type(metric), tags, bucket}
    update_counter_op = {2, 1}
    update_sum_op = {3, round(value)}

    :ets.update_counter(
      metrics_table,
      ets_key,
      [update_counter_op, update_sum_op],
      {ets_key, 0, 0}
    )
  end

  defp find_bucket(%Metrics.Distribution{reporter_options: opts}, value) do
    bucket_bounds = Keyword.get(opts, :buckets, @default_buckets)

    case Enum.find_index(bucket_bounds, &(value <= &1)) do
      # Overflow bucket
      nil -> length(bucket_bounds)
      idx -> idx
    end
  end

  @impl true
  def init(config) do
    metrics = Map.get(config, :metrics, [])
    metrics_table = config.name
    finch_pool = Map.get(config, :finch_pool, OtelMetricExporter.Finch)
    Process.send_after(self(), :export, config.export_period)

    # Create ETS table for metrics
    :ets.new(metrics_table, [:ordered_set, :public, :named_table, {:write_concurrency, true}])

    generations_table = :ets.new(:generations, [:ordered_set, :private])
    :ets.insert(generations_table, {0, System.system_time(:nanosecond), 0})
    :persistent_term.put(generation_key(metrics_table), 0)

    {:ok,
     %State{
       config: config,
       finch_pool: finch_pool,
       metrics: metrics,
       metrics_table: metrics_table,
       generations_table: generations_table
     }}
  end

  @impl true
  def handle_call(:export_sync, _from, state) do
    case export_metrics(state) do
      :ok ->
        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:export, state) do
    Process.send_after(self(), :export, state.config.export_period)
    # Use the same logic as sync export
    case export_metrics(state) do
      :ok ->
        {:noreply, state}

      {:error, _} ->
        {:noreply, state}
    end
  end

  defp build_kv(tags) do
    Enum.map(tags, fn {key, value} ->
      %KeyValue{
        key: to_string(key),
        value: %AnyValue{value: to_kv_value(value)}
      }
    end)
  end

  defp to_kv_value(value) when is_binary(value), do: {:string_value, value}
  defp to_kv_value(value) when is_integer(value), do: {:int_value, value}
  defp to_kv_value(value) when is_float(value), do: {:double_value, value}
  defp to_kv_value(value) when is_boolean(value), do: {:bool_value, value}
  defp to_kv_value(value) when is_struct(value), do: {:string_value, to_string(value)}

  defp to_kv_value(value) when is_list(value),
    do: {:array_value, %ArrayValue{values: Enum.map(value, &%AnyValue{value: to_kv_value(&1)})}}

  defp to_kv_value(value) when is_map(value),
    do: {:kvlist_value, %KeyValueList{values: build_kv(value)}}

  defp rotate_generation(%State{} = state) do
    current_gen = :persistent_term.get(generation_key(state.metrics_table))
    :persistent_term.put(generation_key(state.metrics_table), current_gen + 1)

    :ets.update_element(
      state.generations_table,
      current_gen,
      {3, System.system_time(:nanosecond)}
    )

    :ets.insert(state.generations_table, {current_gen + 1, System.system_time(:nanosecond), nil})

    current_gen
  end

  defp export_metrics(%State{} = state) do
    current_gen = rotate_generation(state)

    earliest_gen =
      case :ets.first(state.generations_table) do
        :"$end_of_table" -> 0
        x -> x
      end

    earliest_gen..current_gen//1
    |> Enum.reduce(%{}, fn gen, acc ->
      {_, start, finish} = List.first(:ets.lookup(state.generations_table, gen), {nil, nil, nil})

      get_metrics(state.metrics_table, gen)
      |> Map.new(fn {metric_key, values} ->
        {metric_key, Enum.map(values, fn {tags, value} -> {{start, finish}, tags, value} end)}
      end)
      |> Map.merge(acc, fn _k, v1, v2 -> v2 ++ v1 end)
    end)
    |> Enum.flat_map(fn {{type, name}, tagged_values} ->
      metric =
        Enum.find(state.metrics, &(Enum.join(&1.name, ".") == name and metric_type(&1) == type))

      convert_metric(metric, tagged_values)
    end)
    |> do_export_metrics(state)
    |> case do
      :ok ->
        # Clear exported metrics
        for x <- earliest_gen..current_gen//1 do
          :ets.match_delete(state.metrics_table, {{x, :_, :_, :_, :_}, :_, :_})
          :ets.delete(state.generations_table, x)
        end

        :ok

      {:error, reason} ->
        Logger.error("Failed to export metrics: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_export_metrics(metrics, %State{} = state) do
    request = %ExportMetricsServiceRequest{
      resource_metrics: [
        %ResourceMetrics{
          resource: %Resource{attributes: build_kv(state.config.resource)},
          scope_metrics: [
            %ScopeMetrics{
              scope: %InstrumentationScope{name: "otel_metric_exporter"},
              metrics: metrics
            }
          ]
        }
      ]
    }

    headers =
      Map.merge(
        %{
          "content-type" => "application/x-protobuf",
          "accept" => "application/x-protobuf"
        },
        state.config.otlp_headers
      )

    request_body = ExportMetricsServiceRequest.encode(request)

    case Finch.build(
           :post,
           state.config.otlp_endpoint <> "/v1/metrics",
           Map.to_list(headers),
           request_body
         )
         |> Finch.request(state.finch_pool) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, response} ->
        {:error, {:unexpected_status, response}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp convert_metric(
         %{name: name, description: description, unit: unit} = metric,
         values
       ) do
    Enum.map(values, fn {{from, to}, tags, value} ->
      suffix = tags |> Enum.sort() |> Enum.map(fn {_k, v} -> v end)

      %Metric{
        name: Enum.join(name ++ suffix, "."),
        description: description,
        unit: convert_unit(unit),
        data: convert_data(metric, from, to, value)
      }
    end)
  end

  defp convert_data(%Metrics.Counter{}, from, to, value) do
    {:sum,
     %Sum{
       data_points: [
         %NumberDataPoint{
           attributes: [],
           start_time_unix_nano: from,
           time_unix_nano: to,
           value: {:as_int, value}
         }
       ],
       aggregation_temporality: :AGGREGATION_TEMPORALITY_CUMULATIVE,
       is_monotonic: true
     }}
  end

  defp convert_data(%Metrics.Sum{}, from, to, value) do
    {:sum,
     %Sum{
       data_points: [
         %NumberDataPoint{
           attributes: [],
           start_time_unix_nano: from,
           time_unix_nano: to,
           value: {:as_int, value}
         }
       ],
       aggregation_temporality: :AGGREGATION_TEMPORALITY_CUMULATIVE,
       is_monotonic: false
     }}
  end

  defp convert_data(%Metrics.LastValue{}, from, to, value) do
    {:gauge,
     %Gauge{
       data_points: [
         %NumberDataPoint{
           attributes: [],
           start_time_unix_nano: from,
           time_unix_nano: to,
           value: {:as_double, value}
         }
       ]
     }}
  end

  defp convert_data(%Metrics.Distribution{reporter_options: opts}, from, to, bucket_values) do
    bucket_bounds = Keyword.get(opts, :buckets, @default_buckets)
    total_bucket_bounds = length(bucket_bounds)

    {total_count, total_sum} =
      Enum.reduce(bucket_values, {0, 0.0}, fn {_, {count, sum}}, {total_count, total_sum} ->
        {total_count + count, total_sum + sum}
      end)

    bucket_counts =
      Enum.map(0..total_bucket_bounds//1, &elem(Map.get(bucket_values, &1, {0, 0}), 0))

    {:histogram,
     %Histogram{
       data_points: [
         %HistogramDataPoint{
           attributes: [],
           start_time_unix_nano: from,
           time_unix_nano: to,
           count: total_count,
           sum: total_sum,
           bucket_counts: bucket_counts,
           explicit_bounds: bucket_bounds
         }
       ],
       aggregation_temporality: :AGGREGATION_TEMPORALITY_CUMULATIVE
     }}
  end

  defp convert_unit(:unit), do: nil
  defp convert_unit(:second), do: "s"
  defp convert_unit(:millisecond), do: "ms"
  defp convert_unit(:microsecond), do: "us"
  defp convert_unit(:nanosecond), do: "ns"
  defp convert_unit(:byte), do: "By"
  defp convert_unit(:kilobyte), do: "kBy"
  defp convert_unit(:megabyte), do: "MBy"
  defp convert_unit(:gigabyte), do: "GBy"
  defp convert_unit(:terabyte), do: "TBy"
  defp convert_unit(x) when is_atom(x), do: Atom.to_string(x)

  defp generation_key(metrics_table) do
    {__MODULE__, metrics_table, :generation}
  end
end
