defmodule OtelMetricExporter.MetricStoreTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias OtelMetricExporter.Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceRequest
  alias Telemetry.Metrics
  alias OtelMetricExporter.MetricStore

  @default_buckets [0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000]

  setup do
    bypass = Bypass.open()
    {:ok, _} = start_supervised({Finch, name: TestFinch})

    config = %{
      otlp_protocol: :http_protobuf,
      otlp_endpoint: "http://localhost:#{bypass.port}",
      otlp_headers: %{},
      otlp_compression: nil,
      resource: %{instance: %{id: "test"}},
      export_period: 1000,
      default_buckets: @default_buckets,
      metrics: [],
      finch_pool: TestFinch
    }

    {:ok, bypass: bypass, store_config: config}
  end

  describe "recording metrics" do
    setup %{store_config: config}, do: {:ok, store: start_supervised!({MetricStore, config})}

    test "records counter metrics" do
      metric = Metrics.counter("test.value")
      tags = %{test: "value"}

      MetricStore.write_metric(metric, 1, tags)
      MetricStore.write_metric(metric, 2, tags)

      metrics = MetricStore.get_metrics()

      assert %{{:counter, "test.value"} => %{^tags => 2}} = metrics
    end

    test "records sum metrics" do
      metric = Metrics.sum("test.value")
      tags = %{test: "value"}

      MetricStore.write_metric(metric, 1, tags)
      MetricStore.write_metric(metric, 2, tags)

      metrics = MetricStore.get_metrics()

      assert %{{:sum, "test.value"} => %{^tags => 3}} = metrics
    end

    test "records last value metrics" do
      metric = Metrics.last_value("test.value")
      tags = %{test: "value"}

      MetricStore.write_metric(metric, 1, tags)
      MetricStore.write_metric(metric, 2, tags)

      metrics = MetricStore.get_metrics()

      assert %{{:last_value, "test.value"} => %{^tags => 2}} = metrics
    end

    test "records distribution metrics" do
      metric = Metrics.distribution("test.value", reporter_options: [buckets: [2, 4]])
      tags = %{test: "value"}

      MetricStore.write_metric(metric, 2, tags)
      MetricStore.write_metric(metric, 3, tags)
      MetricStore.write_metric(metric, 5, tags)
      MetricStore.write_metric(metric, 5, tags)

      metrics = MetricStore.get_metrics()

      assert %{
               {:distribution, "test.value"} => %{
                 ^tags => %{0 => {1, 2}, 1 => {1, 3}, 2 => {2, 10}}
               }
             } = metrics
    end

    test "handles different tag sets independently" do
      metric = Metrics.sum("test.value")
      tags1 = %{test: "value1"}
      tags2 = %{test: "value2"}

      MetricStore.write_metric(metric, 1, tags1)
      MetricStore.write_metric(metric, 2, tags2)
      MetricStore.write_metric(metric, 2, tags1)

      metrics = MetricStore.get_metrics()

      assert %{
               {:sum, "test.value"} => %{^tags1 => 3, ^tags2 => 2}
             } = metrics
    end
  end

  describe "export flow" do
    test "exports all metrics in protobuf format", %{bypass: bypass, store_config: config} do
      metric1 = Metrics.sum("test.sum")
      metric2 = Metrics.counter("test.counter")
      metric3 = Metrics.last_value("test.last_value")
      metric4 = Metrics.distribution("test.distribution")
      start_supervised!({MetricStore, %{config | metrics: [metric1, metric2, metric3, metric4]}})

      tags = %{test: "value"}

      Bypass.expect_once(bypass, "POST", "/v1/metrics", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert {"content-type", "application/x-protobuf"} in conn.req_headers
        assert {"accept", "application/x-protobuf"} in conn.req_headers

        assert body != ""

        # Decodes withouth raising
        ExportMetricsServiceRequest.decode(body)

        Plug.Conn.resp(conn, 200, "")
      end)

      MetricStore.write_metric(metric1, 1, tags)
      MetricStore.write_metric(metric2, 2, tags)
      MetricStore.write_metric(metric3, 3, tags)
      MetricStore.write_metric(metric4, 4, tags)
      MetricStore.write_metric(metric4, 2000, tags)

      metrics = MetricStore.get_metrics()
      assert map_size(metrics) > 0

      # Export metrics synchronously
      assert :ok = MetricStore.export_sync()

      # Verify metrics were cleared
      assert MetricStore.get_metrics(0) == %{}
    end

    test "handles server errors gracefully", %{bypass: bypass, store_config: config} do
      metric = Metrics.sum("test.sum")
      tags = %{test: "value"}
      start_supervised!({MetricStore, %{config | metrics: [metric]}})

      Bypass.expect_once(bypass, "POST", "/v1/metrics", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      MetricStore.write_metric(metric, 1, tags)

      metrics = MetricStore.get_metrics()

      # Export metrics synchronously
      assert capture_log(fn -> MetricStore.export_sync() end) =~ "Failed to export metrics"

      # Verify metrics were not cleared due to error
      assert MetricStore.get_metrics(0) == metrics
    end

    test "handles connection errors gracefully", %{bypass: bypass, store_config: config} do
      metric = Metrics.sum("test.sum")
      tags = %{test: "value"}
      start_supervised!({MetricStore, %{config | metrics: [metric]}})

      Bypass.down(bypass)

      MetricStore.write_metric(metric, 1, tags)

      metrics = MetricStore.get_metrics()

      # Export metrics synchronously
      assert capture_log(fn -> MetricStore.export_sync() end) =~ "Failed to export metrics"

      # Verify metrics were not cleared due to error
      assert MetricStore.get_metrics(0) == metrics
    end

    test "preserves metrics across generations on failed exports", %{
      bypass: bypass,
      store_config: config
    } do
      metric = Metrics.sum("test.sum")
      tags = %{test: "value"}
      start_supervised!({MetricStore, %{config | metrics: [metric]}})

      # First generation
      MetricStore.write_metric(metric, 1, tags)

      # First export fails
      Bypass.expect_once(bypass, "POST", "/v1/metrics", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      capture_log(fn -> MetricStore.export_sync() end)

      # Second generation
      MetricStore.write_metric(metric, 2, tags)

      # Second export succeeds and should include both generations
      Bypass.expect_once(bypass, "POST", "/v1/metrics", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        metrics = ExportMetricsServiceRequest.decode(body)

        # Verify that we have one metric with sum = 3 (1 from first generation + 2 from second)
        assert [%{scope_metrics: [%{metrics: [metric]}]}] = metrics.resource_metrics

        assert {:sum, %{data_points: [point1, point2]}} = metric.data
        assert {:as_int, 1} = point1.value
        assert {:as_int, 2} = point2.value

        assert point1.time_unix_nano < point2.time_unix_nano
        assert point2.start_time_unix_nano > point1.time_unix_nano

        Plug.Conn.resp(conn, 200, "")
      end)

      assert :ok = MetricStore.export_sync()

      # Both generations should be cleared after successful export
      assert MetricStore.get_metrics(0) == %{}
      assert MetricStore.get_metrics(1) == %{}
    end
  end
end
