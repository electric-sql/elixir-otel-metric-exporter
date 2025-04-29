defmodule OtelMetricExporter.LogHandlerIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias OtelMetricExporter.LogHandler
  alias OtelMetricExporter.Opentelemetry.Proto.Collector.Logs.V1.ExportLogsServiceRequest
  alias OtelMetricExporter.Opentelemetry.Proto.Common.V1.AnyValue
  alias OtelMetricExporter.Opentelemetry.Proto.Logs.V1.LogRecord

  require Logger

  @default_config %{
    resource: %{instance: %{id: "integration-test"}},
    # Use small debounce/buffer to make tests predictable
    debounce_ms: 10,
    max_buffer_size: 1,
    # Map request_id from metadata
    metadata_map: %{
      request_id: "http.request.id"
    }
  }

  setup do
    # Use a unique handler ID for each test run
    handler_id = :"handler_#{System.unique_integer([:positive, :monotonic])}"
    bypass = Bypass.open()

    config =
      Map.merge(@default_config, %{
        otlp_endpoint: "http://localhost:#{bypass.port}"
      })

    # Ensure :otel_metric_exporter app env is clean or set if needed,
    # although handler config should override
    # Application.put_env(:otel_metric_exporter, :otlp_endpoint, config.otlp_endpoint)
    # Application.put_env(:otel_metric_exporter, :resource, config.resource)

    # Add the handler for this test
    :ok = :logger.add_handler(handler_id, LogHandler, %{config: config})

    # Ensure the handler is removed after the test finishes
    on_exit(fn ->
      # Wait briefly for logs potentially in flight due to debounce
      Process.sleep(50)
      _ = :logger.remove_handler(handler_id)
      # Clean up app env if needed
      # Application.delete_env(:otel_metric_exporter, :otlp_endpoint)
      # Application.delete_env(:otel_metric_exporter, :resource)
    end)

    {:ok, bypass: bypass, handler_id: handler_id, config: config}
  end

  defp decode_request_body(body) do
    body
    |> :zlib.gunzip()
    |> Protobuf.decode(ExportLogsServiceRequest)
  end

  # --- Test Cases Below ---

  test "captures Logger.info message", %{bypass: bypass} do
    parent = self()

    Bypass.expect_once(bypass, "POST", "/v1/logs", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      %ExportLogsServiceRequest{resource_logs: [%{scope_logs: [%{log_records: logs}]}]} =
        decode_request_body(body)

      send(parent, {:logs, logs})
      Plug.Conn.resp(conn, 200, "")
    end)

    Logger.info("hello info")

    assert_receive {:logs, logs}, 500
    assert [%LogRecord{body: %{value: {:string_value, "hello info"}}}] = logs
  end

  test "captures Logger.error message with correct severity", %{bypass: bypass} do
    parent = self()

    Bypass.expect_once(bypass, "POST", "/v1/logs", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      %ExportLogsServiceRequest{resource_logs: [%{scope_logs: [%{log_records: logs}]}]} =
        decode_request_body(body)

      send(parent, {:logs, logs})
      Plug.Conn.resp(conn, 200, "")
    end)

    Logger.error("hello error")

    assert_receive {:logs, logs}, 500

    assert [
             %LogRecord{
               body: %{value: {:string_value, "hello error"}},
               severity_text: "error",
               severity_number: :SEVERITY_NUMBER_ERROR
             }
           ] = logs
  end

  test "maps metadata fields correctly", %{bypass: bypass} do
    parent = self()
    request_id = "req-12345"

    Bypass.expect_once(bypass, "POST", "/v1/logs", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      %ExportLogsServiceRequest{resource_logs: [%{scope_logs: [%{log_records: logs}]}]} =
        decode_request_body(body)

      send(parent, {:logs, logs})
      Plug.Conn.resp(conn, 200, "")
    end)

    Logger.metadata(request_id: request_id)
    Logger.info("metadata log")

    assert_receive {:logs, logs}, 500

    assert [
             %LogRecord{
               body: %{value: {:string_value, "metadata log"}},
               attributes: attributes
             }
           ] = logs

    assert Enum.any?(attributes, fn attr ->
             attr.key == "http.request.id" &&
               attr.value == %AnyValue{value: {:string_value, request_id}}
           end)
  end

  test "captures logs from an EXIT", %{bypass: bypass} do
    parent = self()
    Process.flag(:trap_exit, true)

    Bypass.expect_once(bypass, "POST", "/v1/logs", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      %ExportLogsServiceRequest{resource_logs: [%{scope_logs: [%{log_records: logs}]}]} =
        decode_request_body(body)

      send(parent, {:logs, logs})
      Plug.Conn.resp(conn, 200, "")
    end)

    {:ok, pid} = Task.start_link(fn -> exit(:crash) end)
    assert_receive {:EXIT, ^pid, :crash}, 500
    assert_receive {:logs, logs}, 500

    assert [
             %LogRecord{
               severity_text: "error",
               body: %{value: {:string_value, error_message}},
               attributes: attributes
             }
           ] = logs

    assert error_message =~ ~r/Task #PID<[\d\.]+> started from #PID<[\d\.]+> terminating/

    attributes =
      Map.new(attributes, fn %{key: key, value: %{value: {:string_value, value}}} ->
        {key, value}
      end)

    assert attributes["exception.message"] == ":crash"
    assert attributes["exception.type"] == "Crash"

    assert attributes["exception.stacktrace"] =~
             ~r|test/otel_metric_exporter/log_handler_integration_test.exs:\d+|
  end

  test "captures logs from an uncaught raise", %{bypass: bypass} do
    parent = self()
    Process.flag(:trap_exit, true)

    Bypass.expect_once(bypass, "POST", "/v1/logs", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      %ExportLogsServiceRequest{resource_logs: [%{scope_logs: [%{log_records: logs}]}]} =
        decode_request_body(body)

      send(parent, {:logs, logs})
      Plug.Conn.resp(conn, 200, "")
    end)

    {:ok, pid} = Task.start_link(fn -> raise RuntimeError, "test error" end)
    assert_receive {:EXIT, ^pid, {%RuntimeError{}, _}}, 500
    assert_receive {:logs, logs}, 500

    assert [
             %LogRecord{
               severity_text: "error",
               body: %{value: {:string_value, error_message}},
               attributes: attributes
             }
           ] = logs

    assert error_message =~ ~r/Task #PID<[\d\.]+> started from #PID<[\d\.]+> terminating/

    attributes =
      Map.new(attributes, fn %{key: key, value: %{value: {:string_value, value}}} ->
        {key, value}
      end)

    assert attributes["exception.message"] == "test error"
    assert attributes["exception.type"] == "Elixir.RuntimeError"

    assert attributes["exception.stacktrace"] =~
             ~r|test/otel_metric_exporter/log_handler_integration_test.exs:\d+|
  end

  test "captures logs from an uncaught throw", %{bypass: bypass} do
    parent = self()
    Process.flag(:trap_exit, true)

    Bypass.expect_once(bypass, "POST", "/v1/logs", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      %ExportLogsServiceRequest{resource_logs: [%{scope_logs: [%{log_records: logs}]}]} =
        decode_request_body(body)

      send(parent, {:logs, logs})
      Plug.Conn.resp(conn, 200, "")
    end)

    {:ok, pid} = Task.start_link(fn -> throw(:test_error) end)
    assert_receive {:EXIT, ^pid, {{:nocatch, :test_error}, _}}, 500
    assert_receive {:logs, logs}, 500

    assert [
             %LogRecord{
               severity_text: "error",
               body: %{value: {:string_value, error_message}},
               attributes: attributes
             }
           ] = logs

    assert error_message =~ ~r/Task #PID<[\d\.]+> started from #PID<[\d\.]+> terminating/

    attributes =
      Map.new(attributes, fn %{key: key, value: %{value: {:string_value, value}}} ->
        {key, value}
      end)

    assert attributes["exception.message"] == "{:nocatch, :test_error}"
    assert attributes["exception.type"] == "Uncaught throw"

    assert attributes["exception.stacktrace"] =~
             ~r|test/otel_metric_exporter/log_handler_integration_test.exs:\d+|
  end

  test "sends batch when max_buffer_size is reached", %{
    bypass: bypass,
    handler_id: handler_id,
    config: initial_config
  } do
    # Reconfigure handler for this specific test, merging with initial config
    new_specific_config = %{max_buffer_size: 3, debounce_ms: 400}
    merged_config = Map.merge(initial_config, new_specific_config)
    :ok = :logger.set_handler_config(handler_id, %{config: merged_config})

    parent = self()

    Bypass.expect(bypass, "POST", "/v1/logs", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      %ExportLogsServiceRequest{resource_logs: [%{scope_logs: [%{log_records: logs}]}]} =
        decode_request_body(body)

      send(parent, {:logs, logs})
      Plug.Conn.resp(conn, 200, "")
    end)

    Logger.info("batch-1")
    Logger.info("batch-2")
    # No request yet
    ref = Process.monitor(bypass.pid)
    refute Process.info(self(), :messages) |> elem(1) |> Enum.any?(&match?({:logs, _}, &1))
    Process.demonitor(ref, [:flush])

    # Third log triggers the send immediately, fourth is in a separate batch after a debouce
    Logger.info("batch-3")
    Logger.info("batch-4")

    assert_receive {:logs, logs}, 500
    # Should receive exactly 3 logs due to buffer size limit
    assert length(logs) == 3

    assert Enum.all?(
             logs,
             &match?(%LogRecord{body: %{value: {:string_value, "batch-" <> _}}}, &1)
           )

    assert_receive {:logs, [_]}, 800
  end

  test "sends batch after debounce_ms timeout", %{
    bypass: bypass,
    handler_id: handler_id,
    config: initial_config
  } do
    debounce_ms = 300
    # Reconfigure handler for this specific test, merging with initial config
    new_specific_config = %{max_buffer_size: 10, debounce_ms: debounce_ms}
    merged_config = Map.merge(initial_config, new_specific_config)
    :ok = :logger.set_handler_config(handler_id, %{config: merged_config})

    parent = self()

    Bypass.expect_once(bypass, "POST", "/v1/logs", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      %ExportLogsServiceRequest{resource_logs: [%{scope_logs: [%{log_records: logs}]}]} =
        decode_request_body(body)

      send(parent, {:logs, logs})
      Plug.Conn.resp(conn, 200, "")
    end)

    Logger.info("debounce log")

    # No request immediately
    ref = Process.monitor(bypass.pid)
    refute Process.info(self(), :messages) |> elem(1) |> Enum.any?(&match?({:logs, _}, &1))
    Process.demonitor(ref, [:flush])

    # Wait for debounce period + some buffer
    Process.sleep(debounce_ms + 50)

    assert_receive {:logs, logs}, 500
    # Should receive the single log after debounce
    assert [%LogRecord{body: %{value: {:string_value, "debounce log"}}}] = logs
  end

  require OpenTelemetry.Tracer, as: Tracer

  test ":opentelemetry trace/span is captured correctly", %{bypass: bypass} do
    parent = self()

    Bypass.expect_once(bypass, "POST", "/v1/logs", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      %ExportLogsServiceRequest{resource_logs: [%{scope_logs: [%{log_records: logs}]}]} =
        decode_request_body(body)

      send(parent, {:logs, logs})
      Plug.Conn.resp(conn, 200, "")
    end)

    span =
      Tracer.with_span "test-span" do
        Logger.info("test-log")
        Tracer.current_span_ctx()
      end

    trace_id = :otel_span.hex_trace_id(span) |> to_string()
    span_id = :otel_span.hex_span_id(span) |> to_string()

    assert_receive {:logs, logs}, 500

    assert [
             %LogRecord{
               body: %{value: {:string_value, "test-log"}},
               trace_id: ^trace_id,
               span_id: ^span_id
             }
           ] = logs
  end
end
