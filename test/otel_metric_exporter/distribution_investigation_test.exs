defmodule OtelMetricExporter.DistributionInvestigationTest do
  @moduledoc """
  Investigation tests for electric-sql/elixir-otel-metric-exporter#20:
  "telemetry_metrics.distribution is not reporting sensible results"

  These tests use synthetic data to confirm that the distribution metric export
  has specific issues with min/max fields and value precision.
  """

  use ExUnit.Case, async: false

  alias OtelMetricExporter.Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceRequest
  alias OtelMetricExporter.Opentelemetry.Proto.Metrics.V1.HistogramDataPoint
  alias Telemetry.Metrics
  alias OtelMetricExporter.MetricStore

  @name :distribution_investigation_test
  @default_buckets [0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000]

  setup do
    bypass = Bypass.open()
    {:ok, _} = start_supervised({Finch, name: DistInvestigationFinch})

    config = %{
      otlp_protocol: :http_protobuf,
      otlp_endpoint: "http://localhost:#{bypass.port}",
      otlp_headers: %{},
      otlp_compression: nil,
      resource: %{instance: %{id: "test"}},
      export_period: 60_000,
      default_buckets: @default_buckets,
      metrics: [],
      finch_pool: DistInvestigationFinch,
      retry: false,
      name: @name
    }

    {:ok, bypass: bypass, store_config: config}
  end

  describe "issue #20: min/max not populated in exported histogram" do
    test "min and max fields are nil in exported HistogramDataPoint", %{
      bypass: bypass,
      store_config: config
    } do
      metric = Metrics.distribution("test.gc.timeout", unit: :millisecond)
      start_supervised!({MetricStore, %{config | metrics: [metric]}})

      tags = %{process_type: "worker"}

      # Write a single value of 668 (matching the issue report)
      MetricStore.write_metric(@name, metric, 668, tags)

      histogram_data_point = export_and_decode_histogram(bypass, @name)

      # CONFIRMED: min and max are nil (not populated by the exporter)
      assert histogram_data_point.min == nil,
             "Expected min to be nil (not tracked), got: #{inspect(histogram_data_point.min)}"

      assert histogram_data_point.max == nil,
             "Expected max to be nil (not tracked), got: #{inspect(histogram_data_point.max)}"

      # count and sum ARE correctly populated
      assert histogram_data_point.count == 1
      assert histogram_data_point.sum == 668.0
    end

    test "min and max remain nil even with multiple data points", %{
      bypass: bypass,
      store_config: config
    } do
      metric = Metrics.distribution("test.schedule.timeout", unit: :millisecond)
      start_supervised!({MetricStore, %{config | metrics: [metric]}})

      tags = %{process_type: "worker"}

      # Write two values matching the second example from the issue (sum=1714, count=2)
      MetricStore.write_metric(@name, metric, 714, tags)
      MetricStore.write_metric(@name, metric, 1000, tags)

      histogram_data_point = export_and_decode_histogram(bypass, @name)

      # CONFIRMED: min and max still nil even with multiple values
      assert histogram_data_point.min == nil
      assert histogram_data_point.max == nil

      # count and sum are correct
      assert histogram_data_point.count == 2
      assert histogram_data_point.sum == 1714.0
    end
  end

  describe "issue #20: value precision loss due to round()" do
    test "fractional values are rounded to integers in sum", %{
      bypass: bypass,
      store_config: config
    } do
      metric = Metrics.distribution("test.latency", unit: :millisecond)
      start_supervised!({MetricStore, %{config | metrics: [metric]}})

      tags = %{}

      # Write a fractional value
      MetricStore.write_metric(@name, metric, 668.7, tags)

      histogram_data_point = export_and_decode_histogram(bypass, @name)

      # CONFIRMED: the sum is rounded — 668.7 becomes 669
      # This is because write_metric uses `round(value)` for the ETS counter update
      assert histogram_data_point.sum == 669.0,
             "Expected sum to be 669.0 (rounded from 668.7), got: #{histogram_data_point.sum}"

      assert histogram_data_point.count == 1
    end

    test "rounding error accumulates across multiple fractional values", %{
      bypass: bypass,
      store_config: config
    } do
      metric = Metrics.distribution("test.latency", unit: :millisecond)
      start_supervised!({MetricStore, %{config | metrics: [metric]}})

      tags = %{}

      # Write several fractional values
      # Exact sum: 1.5 + 2.5 + 3.5 = 7.5
      # Rounded sum: 2 + 2 + 4 = 8 (each value rounded before accumulation)
      # Note: round/1 uses banker's rounding, so 2.5 rounds to 2, not 3
      MetricStore.write_metric(@name, metric, 1.5, tags)
      MetricStore.write_metric(@name, metric, 2.5, tags)
      MetricStore.write_metric(@name, metric, 3.5, tags)

      histogram_data_point = export_and_decode_histogram(bypass, @name)

      # The sum reflects rounded values, not the true sum
      # round(1.5) = 2, round(2.5) = 2 (banker's rounding), round(3.5) = 4
      expected_rounded_sum = round(1.5) + round(2.5) + round(3.5)

      assert histogram_data_point.sum == expected_rounded_sum * 1.0,
             "Expected sum to be #{expected_rounded_sum}.0 (rounded), got: #{histogram_data_point.sum}"
    end
  end

  describe "issue #20: bucket assignment verification" do
    test "values are assigned to correct buckets with default bounds", %{
      bypass: bypass,
      store_config: config
    } do
      metric = Metrics.distribution("test.gc.timeout", unit: :millisecond)
      start_supervised!({MetricStore, %{config | metrics: [metric]}})

      tags = %{process_type: "worker"}

      # Value 668 should go into bucket index 9 (bound 750, i.e., 500 < 668 <= 750)
      MetricStore.write_metric(@name, metric, 668, tags)

      histogram_data_point = export_and_decode_histogram(bypass, @name)

      # Default buckets: [0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, ...]
      # 668 <= 750, so bucket index 9 should have count=1
      # There are 16 bucket counts (15 bounds + 1 overflow)
      assert length(histogram_data_point.bucket_counts) == length(@default_buckets) + 1

      # Only bucket index 9 (<=750) should have a count
      assert Enum.at(histogram_data_point.bucket_counts, 9) == 1

      # All other buckets should be 0
      histogram_data_point.bucket_counts
      |> Enum.with_index()
      |> Enum.each(fn {count, idx} ->
        if idx != 9 do
          assert count == 0,
                 "Expected bucket #{idx} to be 0, got: #{count}"
        end
      end)

      assert histogram_data_point.explicit_bounds == @default_buckets
    end

    test "reproduces issue scenario: single value 668 with default buckets", %{
      bypass: bypass,
      store_config: config
    } do
      # This test reproduces the exact scenario from issue #20, example 1
      metric = Metrics.distribution("vm.monitor.long_gc.timeout", unit: :millisecond)
      start_supervised!({MetricStore, %{config | metrics: [metric]}})

      tags = %{process_type: "worker"}
      MetricStore.write_metric(@name, metric, 668, tags)

      histogram_data_point = export_and_decode_histogram(bypass, @name)

      # What gets exported:
      assert histogram_data_point.count == 1
      assert histogram_data_point.sum == 668.0
      assert histogram_data_point.min == nil  # NOT POPULATED — reported as 0 by Honeycomb
      assert histogram_data_point.max == nil  # NOT POPULATED — reported as 0 by Honeycomb

      # The value 668 is in the (500, 750] bucket.
      # Honeycomb can only estimate percentiles from bucket boundaries,
      # so it reports all percentiles as 500 (the lower bound of the bucket).
      # This is an inherent limitation of histogram-based distribution metrics,
      # but the missing min/max is a bug in the exporter.
      bucket_index_for_750 = Enum.find_index(@default_buckets, &(&1 == 750))
      assert Enum.at(histogram_data_point.bucket_counts, bucket_index_for_750) == 1
    end

    test "reproduces issue scenario: two values across different buckets", %{
      bypass: bypass,
      store_config: config
    } do
      # This test reproduces the exact scenario from issue #20, example 2
      metric = Metrics.distribution("vm.monitor.long_schedule.timeout", unit: :millisecond)
      start_supervised!({MetricStore, %{config | metrics: [metric]}})

      tags = %{process_type: "worker"}

      # Two values: one ~714 (bucket <=750) and one ~1000 (bucket <=1000)
      MetricStore.write_metric(@name, metric, 714, tags)
      MetricStore.write_metric(@name, metric, 1000, tags)

      histogram_data_point = export_and_decode_histogram(bypass, @name)

      assert histogram_data_point.count == 2
      assert histogram_data_point.sum == 1714.0
      assert histogram_data_point.min == nil
      assert histogram_data_point.max == nil

      # 714 goes into bucket <=750 (index 9)
      # 1000 goes into bucket <=1000 (index 10)
      bucket_index_for_750 = Enum.find_index(@default_buckets, &(&1 == 750))
      bucket_index_for_1000 = Enum.find_index(@default_buckets, &(&1 == 1000))

      assert Enum.at(histogram_data_point.bucket_counts, bucket_index_for_750) == 1
      assert Enum.at(histogram_data_point.bucket_counts, bucket_index_for_1000) == 1

      # Honeycomb estimates percentiles from these buckets:
      # - Lower percentiles (p01-p25) → lower bound of first populated bucket → 500
      # - Higher percentiles (p50-p999) → lower bound of second populated bucket → 750 or 1000
      # This matches the issue report where lower percentiles=500, higher=1000
    end
  end

  describe "issue #20: bucket boundary edge cases" do
    test "value exactly on a bucket boundary goes into that bucket", %{
      bypass: bypass,
      store_config: config
    } do
      metric = Metrics.distribution("test.latency", reporter_options: [buckets: [10, 20, 30]])
      start_supervised!({MetricStore, %{config | metrics: [metric]}})

      tags = %{}

      # Value exactly equal to a bound (10) should go into that bucket (<=10)
      MetricStore.write_metric(@name, metric, 10, tags)

      histogram_data_point = export_and_decode_histogram(bypass, @name)

      # Bucket 0: <=10, should have count=1
      assert Enum.at(histogram_data_point.bucket_counts, 0) == 1
      assert histogram_data_point.count == 1
    end

    test "value exceeding all bucket bounds goes into overflow bucket", %{
      bypass: bypass,
      store_config: config
    } do
      metric = Metrics.distribution("test.latency", reporter_options: [buckets: [10, 20, 30]])
      start_supervised!({MetricStore, %{config | metrics: [metric]}})

      tags = %{}

      MetricStore.write_metric(@name, metric, 100, tags)

      histogram_data_point = export_and_decode_histogram(bypass, @name)

      # Overflow bucket (index 3 for 3 bounds) should have count=1
      assert Enum.at(histogram_data_point.bucket_counts, 3) == 1
      assert histogram_data_point.count == 1
    end
  end

  # Helper: exports metrics and returns the single HistogramDataPoint
  defp export_and_decode_histogram(bypass, name) do
    histogram_data_point_ref = make_ref()
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/v1/metrics", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = ExportMetricsServiceRequest.decode(body)

      [resource_metrics] = request.resource_metrics
      [scope_metrics] = resource_metrics.scope_metrics
      [metric] = scope_metrics.metrics

      {:histogram, histogram} = metric.data
      [data_point] = histogram.data_points

      send(test_pid, {histogram_data_point_ref, data_point})
      Plug.Conn.resp(conn, 200, "")
    end)

    assert :ok = MetricStore.export_sync(name)

    receive do
      {^histogram_data_point_ref, %HistogramDataPoint{} = data_point} -> data_point
    after
      5000 -> flunk("Timed out waiting for histogram data point")
    end
  end
end
