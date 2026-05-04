defmodule OtelMetricExporter.MetricStoreTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias OtelMetricExporter.Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceRequest
  alias Telemetry.Metrics
  alias OtelMetricExporter.MetricStore

  @name :metric_store_test
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
      finch_pool: TestFinch,
      retry: false,
      name: @name
    }

    {:ok, bypass: bypass, store_config: config}
  end

  describe "recording metrics" do
    setup %{store_config: config}, do: {:ok, store: start_supervised!({MetricStore, config})}

    test "records counter metrics" do
      metric = Metrics.counter("test.value")
      tags = %{test: "value"}

      MetricStore.write_metric(@name, metric, 1, tags)
      MetricStore.write_metric(@name, metric, 2, tags)

      metrics = MetricStore.get_metrics(@name)

      assert %{{:counter, "test.value"} => %{^tags => 2}} = metrics
    end

    test "records sum metrics" do
      metric = Metrics.sum("test.value")
      tags = %{test: "value"}

      MetricStore.write_metric(@name, metric, 1, tags)
      MetricStore.write_metric(@name, metric, 2, tags)

      metrics = MetricStore.get_metrics(@name)

      assert %{{:sum, "test.value"} => %{^tags => 3}} = metrics
    end

    test "records last value metrics" do
      metric = Metrics.last_value("test.value")
      tags = %{test: "value"}

      MetricStore.write_metric(@name, metric, 1, tags)
      MetricStore.write_metric(@name, metric, 2, tags)

      metrics = MetricStore.get_metrics(@name)

      assert %{{:last_value, "test.value"} => %{^tags => 2}} = metrics
    end

    test "records distribution metrics" do
      metric = Metrics.distribution("test.value", reporter_options: [buckets: [2, 4]])
      tags = %{test: "value"}

      MetricStore.write_metric(@name, metric, 2, tags)
      MetricStore.write_metric(@name, metric, 3, tags)
      MetricStore.write_metric(@name, metric, 5, tags)
      MetricStore.write_metric(@name, metric, 5, tags)

      metrics = MetricStore.get_metrics(@name)

      assert %{
               {:distribution, "test.value"} => %{
                 ^tags => %{0 => {1, 2}, 1 => {1, 3}, 2 => {2, 10}, min: {2, nil}, max: {5, nil}}
               }
             } = metrics
    end

    test "handles different tag sets independently" do
      metric = Metrics.sum("test.value")
      tags1 = %{test: "value1"}
      tags2 = %{test: "value2"}

      MetricStore.write_metric(@name, metric, 1, tags1)
      MetricStore.write_metric(@name, metric, 2, tags2)
      MetricStore.write_metric(@name, metric, 2, tags1)

      metrics = MetricStore.get_metrics(@name)

      assert %{
               {:sum, "test.value"} => %{^tags1 => 3, ^tags2 => 2}
             } = metrics
    end
  end

  describe "export flow" do
    test "exports all metrics in protobuf format", %{bypass: bypass, store_config: config} do
      metrics =
        [metric1, metric2, metric_lv_int, metric_lv_bigint, metric_lv_float, metric4] =
        [
          Metrics.sum("test.sum"),
          Metrics.counter("test.counter"),
          Metrics.last_value("test.last_value.int"),
          Metrics.last_value("test.last_value.bigint"),
          Metrics.last_value("test.last_value.float"),
          Metrics.distribution("test.distribution")
        ]

      start_supervised!({MetricStore, %{config | metrics: metrics}})

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

      MetricStore.write_metric(@name, metric1, 1, tags)
      MetricStore.write_metric(@name, metric2, 2, tags)
      MetricStore.write_metric(@name, metric_lv_int, 2 ** 63 - 1, tags)
      MetricStore.write_metric(@name, metric_lv_bigint, 2 ** 70, tags)
      MetricStore.write_metric(@name, metric_lv_float, -1.5, tags)
      MetricStore.write_metric(@name, metric4, 4, tags)
      MetricStore.write_metric(@name, metric4, 2000, tags)

      metrics = MetricStore.get_metrics(@name)
      assert map_size(metrics) > 0

      # Export metrics synchronously
      assert :ok = MetricStore.export_sync(@name)

      # Verify metrics were cleared
      assert MetricStore.get_metrics(@name, 0) == %{}
    end

    test "exports nil and :undefined last_value as a nil data point without crashing", %{
      bypass: bypass,
      store_config: config
    } do
      metric_undef = Metrics.last_value("test.last_value.undefined")
      metric_nil = Metrics.last_value("test.last_value.nil")
      tags = %{test: "value"}
      start_supervised!({MetricStore, %{config | metrics: [metric_undef, metric_nil]}})

      Bypass.expect_once(bypass, "POST", "/v1/metrics", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = ExportMetricsServiceRequest.decode(body)

        assert [%{scope_metrics: [%{metrics: exported_metrics}]}] = decoded.resource_metrics

        Enum.each(exported_metrics, fn metric ->
          assert {:gauge, %{data_points: [point]}} = metric.data
          # protobuf elides the nil inner value, so the oneof decodes as nil
          assert point.value == nil
        end)

        Plug.Conn.resp(conn, 200, "")
      end)

      # `:telemetry` emits `:undefined` for uninitialised values
      MetricStore.write_metric(@name, metric_undef, :undefined, tags)

      # A `nil` value may slip in just as well
      MetricStore.write_metric(@name, metric_nil, nil, tags)

      assert :ok = MetricStore.export_sync(@name)
    end

    test "handles server errors gracefully", %{bypass: bypass, store_config: config} do
      metric = Metrics.sum("test.sum")
      tags = %{test: "value"}
      start_supervised!({MetricStore, %{config | metrics: [metric]}})

      Bypass.expect_once(bypass, "POST", "/v1/metrics", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      MetricStore.write_metric(@name, metric, 1, tags)

      metrics = MetricStore.get_metrics(@name)

      # Export metrics synchronously
      assert capture_log(fn -> MetricStore.export_sync(@name) end) =~ "Failed to export metrics"

      # Verify metrics were not cleared due to error
      assert MetricStore.get_metrics(@name, 0) == metrics
    end

    test "handles connection errors gracefully", %{bypass: bypass, store_config: config} do
      metric = Metrics.sum("test.sum")
      tags = %{test: "value"}
      start_supervised!({MetricStore, %{config | metrics: [metric]}})

      Bypass.down(bypass)

      MetricStore.write_metric(@name, metric, 1, tags)

      metrics = MetricStore.get_metrics(@name)

      # Export metrics synchronously
      assert capture_log(fn -> MetricStore.export_sync(@name) end) =~ "Failed to export metrics"

      # Verify metrics were not cleared due to error
      assert MetricStore.get_metrics(@name, 0) == metrics
    end

    test "reaggregates metrics across generations on failed exports", %{
      bypass: bypass,
      store_config: config
    } do
      metric = Metrics.sum("test.sum")
      tags = %{test: "value"}
      start_supervised!({MetricStore, %{config | metrics: [metric]}})

      # First generation
      MetricStore.write_metric(@name, metric, 1, tags)

      # First export fails
      Bypass.expect_once(bypass, "POST", "/v1/metrics", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      capture_log(fn -> MetricStore.export_sync(@name) end)

      # Second generation
      MetricStore.write_metric(@name, metric, 2, tags)

      # Second export succeeds and should contain a single reaggregated data point
      # spanning both generations (sum = 3) instead of one point per generation.
      # This prevents the request payload from growing unboundedly across repeated
      # export failures (see electric-sql/stratovolt#1455).
      Bypass.expect_once(bypass, "POST", "/v1/metrics", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        metrics = ExportMetricsServiceRequest.decode(body)

        assert [%{scope_metrics: [%{metrics: [metric]}]}] = metrics.resource_metrics

        assert {:sum, %{data_points: [point]}} = metric.data
        assert {:as_int, 3} = point.value
        assert point.start_time_unix_nano <= point.time_unix_nano

        Plug.Conn.resp(conn, 200, "")
      end)

      assert :ok = MetricStore.export_sync(@name)

      # All generations should be cleared after successful export
      assert MetricStore.get_metrics(@name, 0) == %{}
      assert MetricStore.get_metrics(@name, 1) == %{}
      assert MetricStore.get_metrics(@name, 2) == %{}
    end

    test "reaggregation across failures keeps payload size bounded", %{
      bypass: bypass,
      store_config: config
    } do
      metric = Metrics.sum("test.sum")
      tags = %{test: "value"}
      start_supervised!({MetricStore, %{config | metrics: [metric]}})

      # Simulate multiple consecutive export failures.
      Bypass.expect(bypass, "POST", "/v1/metrics", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      for i <- 1..5 do
        MetricStore.write_metric(@name, metric, i, tags)
        capture_log(fn -> MetricStore.export_sync(@name) end)
      end

      Bypass.down(bypass)
      Bypass.up(bypass)

      # Next successful export should contain exactly one data point with the
      # cumulative sum, not five points.
      Bypass.expect_once(bypass, "POST", "/v1/metrics", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        metrics = ExportMetricsServiceRequest.decode(body)

        assert [%{scope_metrics: [%{metrics: [metric]}]}] = metrics.resource_metrics
        assert {:sum, %{data_points: [point]}} = metric.data
        assert {:as_int, 15} = point.value

        Plug.Conn.resp(conn, 200, "")
      end)

      assert :ok = MetricStore.export_sync(@name)
    end
  end
end
