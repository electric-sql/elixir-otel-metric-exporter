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
                 ^tags => %{0 => {1, 2}, 1 => {1, 3}, 2 => {2, 10}}
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

      MetricStore.write_metric(@name, metric1, 1, tags)
      MetricStore.write_metric(@name, metric2, 2, tags)
      MetricStore.write_metric(@name, metric3, 3, tags)
      MetricStore.write_metric(@name, metric4, 4, tags)
      MetricStore.write_metric(@name, metric4, 2000, tags)

      metrics = MetricStore.get_metrics(@name)
      assert map_size(metrics) > 0

      # Export metrics synchronously
      assert :ok = MetricStore.export_sync(@name)

      # Verify metrics were cleared
      assert MetricStore.get_metrics(@name, 0) == %{}
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
      assert capture_log(fn -> MetricStore.export_sync(@name) end) =~ "Failed to export batch"

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
      assert capture_log(fn -> MetricStore.export_sync(@name) end) =~ "Failed to export batch"

      # Verify metrics were not cleared due to error
      assert MetricStore.get_metrics(@name, 0) == metrics
    end

    test "preserves metrics across generations on failed exports", %{
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

      assert :ok = MetricStore.export_sync(@name)

      # Both generations should be cleared after successful export
      assert MetricStore.get_metrics(@name, 0) == %{}
      assert MetricStore.get_metrics(@name, 1) == %{}
    end

    test "splits large metric sets into batches", %{bypass: bypass, store_config: config} do
      metrics = Enum.map(1..60, &Metrics.counter("test.counter.#{&1}"))
      start_supervised!({MetricStore, Map.merge(config, %{metrics: metrics, max_batch_size: 50})})

      Enum.each(metrics, &MetricStore.write_metric(@name, &1, 1, %{}))

      {:ok, agent} = Agent.start_link(fn -> [] end)

      Bypass.expect(bypass, "POST", "/v1/metrics", fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)

        [%{scope_metrics: [%{metrics: batch}]}] =
          ExportMetricsServiceRequest.decode(body).resource_metrics

        Agent.update(agent, &[length(batch) | &1])
        Plug.Conn.resp(conn, 200, "")
      end)

      assert :ok = MetricStore.export_sync(@name)
      assert MetricStore.get_metrics(@name, 0) == %{}
      assert Agent.get(agent, & &1) |> Enum.sort() == [10, 50]
    end

    test "splits large metric data points into smaller sets", %{
      bypass: bypass,
      store_config: config
    } do
      metrics =
        Enum.map(1..60, fn _ -> Metrics.last_value("test.counter.1", tags: [:my_field]) end)

      start_supervised!({MetricStore, Map.merge(config, %{metrics: metrics, max_batch_size: 50})})

      Enum.each(
        metrics,
        &MetricStore.write_metric(@name, &1, 1, %{my_field: "counter_#{:rand.uniform(100_000)}"})
      )

      {:ok, agent} = Agent.start_link(fn -> [] end)

      Bypass.expect(bypass, "POST", "/v1/metrics", fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)

        [%{scope_metrics: [%{metrics: [%{data: {:gauge, %{data_points: data_points}}}]}]}] =
          ExportMetricsServiceRequest.decode(body).resource_metrics

        Agent.update(agent, &[length(data_points) | &1])
        Plug.Conn.resp(conn, 200, "")
      end)

      assert :ok = MetricStore.export_sync(@name)
      assert MetricStore.get_metrics(@name, 0) == %{}

      for v <- Agent.get(agent, & &1) do
        assert v <= 50
      end
    end

    test "retains only failed batch metrics", %{bypass: bypass, store_config: config} do
      metrics = Enum.map(1..60, &Metrics.counter("test.counter.#{&1}"))
      start_supervised!({MetricStore, Map.merge(config, %{metrics: metrics, max_batch_size: 50})})

      Enum.each(metrics, &MetricStore.write_metric(@name, &1, 1, %{}))

      Bypass.expect(bypass, "POST", "/v1/metrics", fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)

        [%{scope_metrics: [%{metrics: batch}]}] =
          ExportMetricsServiceRequest.decode(body).resource_metrics

        status = if length(batch) == 50, do: 200, else: 500
        Plug.Conn.resp(conn, status, "")
      end)

      :timer.sleep(500)

      log =
        capture_log(fn -> assert {:error, :partial_failure} = MetricStore.export_sync(@name) end)

      assert log =~ "Failed to export batch"

      # First batch (50 metrics) succeeds and is cleared, second batch (10 metrics) fails and is retained
      assert map_size(MetricStore.get_metrics(@name, 0)) == 10
    end
  end
end
