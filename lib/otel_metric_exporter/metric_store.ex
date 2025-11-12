defmodule OtelMetricExporter.MetricStore do
  @moduledoc false

  use GenServer

  require Logger

  alias Telemetry.Metrics

  alias OtelMetricExporter.Opentelemetry.Proto.Metrics.V1.{
    Metric,
    NumberDataPoint,
    HistogramDataPoint,
    Sum,
    Gauge,
    Histogram
  }

  alias OtelMetricExporter.OtelApi

  import OtelMetricExporter.OtlpUtils, only: [build_kv: 1]

  @default_buckets [0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000]

  defmodule State do
    @moduledoc false
    defstruct [:config, :api, :metrics, :metrics_table, :last_export, :generations_table]

    @type t :: %__MODULE__{
            config: map(),
            api: struct(),
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
    GenServer.call(name, :export_sync, :infinity)
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

  def table_exists?(metrics_table) do
    case :ets.whereis(metrics_table) do
      :undefined -> false
      tid when is_reference(tid) -> true
    end
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

    with {:ok, api, config} <- OtelApi.new(Map.put(config, :finch, finch_pool), :metrics) do
      {:ok,
       %State{
         config: config,
         api: api,
         metrics: metrics,
         metrics_table: metrics_table,
         generations_table: generations_table
       }}
    end
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
    {duration, _} = :timer.tc(fn -> export_metrics(state) end, :millisecond)

    # schedule after we've sent to avoid problems when there's some kind of
    # problem sending and we get into a retry loop but take into account
    # time taken to send so we keep flushing the data on a regular interval
    Process.send_after(self(), :export, max(state.config.export_period - duration, 100))

    {:noreply, state}
  end

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

    metrics =
      earliest_gen..current_gen//1
      |> Enum.flat_map(fn gen ->
        {_, start, finish} =
          List.first(:ets.lookup(state.generations_table, gen), {nil, nil, nil})

        get_metrics(state.metrics_table, gen)
        |> Enum.map(fn {key, values} ->
          tagged_values = Enum.map(values, fn {tags, value} -> {{start, finish}, tags, value} end)
          {key, tagged_values}
        end)
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {{type, name}, grouped_values} ->
        metric =
          Enum.find(state.metrics, &(Enum.join(&1.name, ".") == name and metric_type(&1) == type))

        convert_metric(metric, List.flatten(grouped_values))
      end)

    tasks =
      metrics
      |> create_batches(state.api.config.max_batch_size)
      |> Enum.map(fn batch ->
        Task.async(fn -> {batch, OtelApi.send_metrics(state.api, batch)} end)
      end)

    yielded_results = Task.yield_many(tasks, timeout: 15_000)

    successful_keys =
      Enum.reduce(yielded_results, [], fn
        {_task, {:ok, {batch, :ok}}}, acc ->
          new_keys = for %Metric{name: name, data: data} <- batch, do: {otlp_data_type(data), name}
          new_keys ++ acc

        {_task, {:ok, {__batch, {:error, reason}}}}, acc ->
          Logger.warning("Failed to export batch: #{inspect(reason)}")
          acc

        {_task, {:ok, other}}, acc ->
          Logger.warning("Unexpected batch result: #{inspect(other)}")
          acc
        {_task, {:exit, reason}}, acc ->
          Logger.warning("Batch export task crashed: #{inspect(reason)}")
          acc

        {task, nil}, acc ->
          Task.shutdown(task, :brutal_kill)
          Logger.warning("Batch export task exceeded 15s timeout and was killed")
          acc
      end)

    # Deduplicate successful_keys since split metrics have the same name/type
    unique_successful_keys = MapSet.new(successful_keys)

    if MapSet.size(unique_successful_keys) == length(metrics) and metrics != [] do
      clear_generations(state, earliest_gen..current_gen//1)
      :ok
    else
      unless successful_keys == [] do
        delete_metrics_by_keys(state, earliest_gen..current_gen//1, unique_successful_keys)
      end

      # fallback to prune old generations if we do not have 100% success
      max_generations_to_hold = Map.get(state.api.config, :max_generations, 5)

      if current_gen - earliest_gen >= max_generations_to_hold do
        force_clear_range = earliest_gen..(current_gen - max_generations_to_hold)//1
        clear_generations(state, force_clear_range)
      end

      {:error, :partial_failure}
    end
  end

  defp create_batches(metrics, max_batch_size) do
    do_create_batches(metrics, max_batch_size, [], 0, [])
  end

  defp do_create_batches([], _max_size, [], _current_count, acc) do
    Enum.reverse(acc)
  end

  defp do_create_batches([], _max_size, current_batch, _current_count, acc) do
    Enum.reverse([Enum.reverse(current_batch) | acc])
  end

  defp do_create_batches([metric | rest], max_size, current_batch, current_count, acc) do
    metric_count = count_data_points(metric)

    cond do
      # Metric fits in current batch
      current_count + metric_count <= max_size ->
        do_create_batches(
          rest,
          max_size,
          [metric | current_batch],
          current_count + metric_count,
          acc
        )

      # Metric needs to be split
      metric_count > max_size ->
        chunks = split_metric(metric, max_size)
        new_acc = if current_batch == [], do: acc, else: [Enum.reverse(current_batch) | acc]
        do_create_batches(chunks ++ rest, max_size, [], 0, new_acc)

      # Emit current batch and start new one with this metric
      true ->
        new_acc = if current_batch == [], do: acc, else: [Enum.reverse(current_batch) | acc]
        do_create_batches(rest, max_size, [metric], metric_count, new_acc)
    end
  end

  defp count_data_points(%Metric{data: {_, %_{data_points: data_points}}}),
    do: Enum.count(data_points)

  defp split_metric(
         %Metric{name: name, description: description, unit: unit, data: {data_type, data_struct}} =
           _metric,
         max_batch_size
       ) do
    data_points = data_struct.data_points

    data_points
    |> Enum.chunk_every(max_batch_size)
    |> Enum.map(fn chunk ->
      %Metric{
        name: name,
        description: description,
        unit: unit,
        data: {data_type, Map.put(data_struct, :data_points, chunk)}
      }
    end)
  end

  defp convert_metric(
         %{name: name, description: description, unit: unit} = metric,
         values
       ) do
    %Metric{
      name: Enum.join(name, "."),
      description: description,
      unit: convert_unit(unit),
      data: convert_data(metric, values)
    }
  end

  defp convert_data(%Metrics.Counter{}, values) do
    {:sum,
     %Sum{
       data_points:
         Enum.map(values, fn {{from, to}, tags, value} ->
           %NumberDataPoint{
             attributes: build_kv(tags),
             start_time_unix_nano: from,
             time_unix_nano: to,
             value: {:as_int, value}
           }
         end),
       aggregation_temporality: :AGGREGATION_TEMPORALITY_CUMULATIVE,
       is_monotonic: true
     }}
  end

  defp convert_data(%Metrics.Sum{}, values) do
    {:sum,
     %Sum{
       data_points:
         Enum.map(values, fn {{from, to}, tags, value} ->
           %NumberDataPoint{
             attributes: build_kv(tags),
             start_time_unix_nano: from,
             time_unix_nano: to,
             value: {:as_int, value}
           }
         end),
       aggregation_temporality: :AGGREGATION_TEMPORALITY_CUMULATIVE,
       is_monotonic: false
     }}
  end

  defp convert_data(%Metrics.LastValue{}, values) do
    {:gauge,
     %Gauge{
       data_points:
         Enum.map(values, fn {{from, to}, tags, value} ->
           %NumberDataPoint{
             attributes: build_kv(tags),
             start_time_unix_nano: from,
             time_unix_nano: to,
             value: {:as_double, value}
           }
         end)
     }}
  end

  defp convert_data(%Metrics.Distribution{reporter_options: opts}, values) do
    bucket_bounds = Keyword.get(opts, :buckets, @default_buckets)
    total_bucket_bounds = length(bucket_bounds)

    {:histogram,
     %Histogram{
       data_points:
         Enum.map(values, fn {{from, to}, tags, bucket_values} ->
           {total_count, total_sum} =
             Enum.reduce(bucket_values, {0, 0.0}, fn {_, {count, sum}},
                                                     {total_count, total_sum} ->
               {total_count + count, total_sum + sum}
             end)

           bucket_counts =
             Enum.map(0..total_bucket_bounds//1, &elem(Map.get(bucket_values, &1, {0, 0}), 0))

           %HistogramDataPoint{
             attributes: build_kv(tags),
             start_time_unix_nano: from,
             time_unix_nano: to,
             count: total_count,
             sum: total_sum,
             bucket_counts: bucket_counts,
             explicit_bounds: bucket_bounds
           }
         end),
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

  defp otlp_data_type({:sum, %Sum{is_monotonic: true}}), do: :counter
  defp otlp_data_type({:sum, _}), do: :sum
  defp otlp_data_type({:gauge, _}), do: :last_value
  defp otlp_data_type({:histogram, _}), do: :distribution

  defp clear_generations(state, range) do
    for gen <- range do
      :ets.match_delete(state.metrics_table, {{gen, :_, :_, :_, :_}, :_, :_})
      :ets.delete(state.generations_table, gen)
    end
  end

  defp delete_metrics_by_keys(state, range, keys) do
    for gen <- range do
      for {type, name} <- keys do
        :ets.match_delete(state.metrics_table, {{gen, name, type, :_, :_}, :_, :_})
      end

      if :ets.match_object(state.metrics_table, {{gen, :_, :_, :_, :_}, :_, :_}) == [] do
        :ets.delete(state.generations_table, gen)
      end
    end
  end
  defp generation_key(metrics_table) do
    {__MODULE__, metrics_table, :generation}
  end
end
