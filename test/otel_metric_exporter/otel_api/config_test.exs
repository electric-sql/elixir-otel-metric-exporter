defmodule OtelMetricExporter.OtelApi.ConfigTest do
  use ExUnit.Case, async: false

  @touched_envs ~w|OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_PROTOCOL OTEL_EXPORTER_OTLP_HEADERS OTEL_EXPORTER_OTLP_TIMEOUT| ++
                  ~w|OTEL_RESOURCE_ATTRIBUTES OTEL_SERVICE_NAME| ++
                  ~w|OTEL_EXPORTER_OTLP_LOGS_ENDPOINT OTEL_EXPORTER_OTLP_LOGS_PROTOCOL OTEL_EXPORTER_OTLP_LOGS_HEADERS OTEL_EXPORTER_OTLP_LOGS_TIMEOUT| ++
                  ~w|OTEL_EXPORTER_OTLP_METRICS_ENDPOINT OTEL_EXPORTER_OTLP_METRICS_PROTOCOL OTEL_EXPORTER_OTLP_METRICS_HEADERS OTEL_EXPORTER_OTLP_METRICS_TIMEOUT| ++
                  ~w|OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER|

  setup do
    on_exit(fn ->
      for env <- @touched_envs do
        System.delete_env(env)
      end

      Application.get_all_env(:otel_metric_exporter)
      |> Keyword.keys()
      |> Enum.each(fn key ->
        Application.delete_env(:otel_metric_exporter, key)
      end)
    end)

    :ok
  end

  describe "defaults" do
    test "returns the default values" do
      assert OtelMetricExporter.OtelApi.Config.defaults() ==
               {:ok,
                %{
                  logs: %{
                    exporter: :otlp
                  },
                  metrics: %{
                    exporter: :otlp
                  },
                  otlp_compression: :gzip,
                  otlp_concurrent_requests: 50,
                  max_batch_size: 500,
                  resource: %{},
                  otlp_headers: %{},
                  otlp_protocol: :http_protobuf,
                  otlp_timeout: 10000,
                  export_callback: nil
                }}
    end

    test "can be overridden by env vars" do
      System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317")
      System.put_env("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "http://localhost:4318")
      System.put_env("OTEL_EXPORTER_OTLP_METRICS_HEADERS", "key1=value1,key2=value2")
      System.put_env("OTEL_EXPORTER_OTLP_TIMEOUT", "10000")
      System.put_env("OTEL_METRICS_EXPORTER", "none")

      assert OtelMetricExporter.OtelApi.Config.defaults() ==
               {:ok,
                %{
                  logs: %{
                    exporter: :otlp,
                    otlp_endpoint: "http://localhost:4318"
                  },
                  metrics: %{
                    exporter: :none,
                    otlp_headers: %{"key1" => "value1", "key2" => "value2"}
                  },
                  otlp_compression: :gzip,
                  otlp_concurrent_requests: 50,
                  max_batch_size: 500,
                  resource: %{},
                  otlp_headers: %{},
                  otlp_protocol: :http_protobuf,
                  otlp_timeout: 10000,
                  otlp_endpoint: "http://localhost:4317",
                  export_callback: nil
                }}
    end

    test "can be set by application config that overrides env vars" do
      System.put_env("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "http://localhost:1010")
      System.put_env("OTEL_EXPORTER_OTLP_METRICS_HEADERS", "key1=value1,key2=value2")

      Application.put_env(:otel_metric_exporter, :otlp_endpoint, "http://localhost:4317")

      Application.put_env(:otel_metric_exporter, :logs, otlp_endpoint: "http://localhost:4318")

      Application.put_env(:otel_metric_exporter, :metrics, %{exporter: :none})

      assert OtelMetricExporter.OtelApi.Config.defaults() ==
               {:ok,
                %{
                  logs: %{
                    exporter: :otlp,
                    otlp_endpoint: "http://localhost:4318"
                  },
                  metrics: %{
                    exporter: :none,
                    otlp_headers: %{"key1" => "value1", "key2" => "value2"}
                  },
                  otlp_compression: :gzip,
                  otlp_concurrent_requests: 50,
                  max_batch_size: 500,
                  resource: %{},
                  otlp_headers: %{},
                  otlp_protocol: :http_protobuf,
                  otlp_timeout: 10000,
                  otlp_endpoint: "http://localhost:4317",
                  export_callback: nil
                }}
    end
  end

  describe "validate_for_scope/2" do
    test "returns error if otlp endpoint is not provided" do
      assert {:error, %{key: :otlp_endpoint}} =
               OtelMetricExporter.OtelApi.Config.validate_for_scope(
                 %{logs: %{exporter: :otlp}},
                 :logs
               )
    end

    test "merges the base config with the scope specific config" do
      System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")
      System.put_env("OTEL_EXPORTER_OTLP_TIMEOUT", "5")

      Application.put_env(:otel_metric_exporter, :logs,
        otlp_headers: %{"key1" => "value1", "key2" => "value2"},
        otlp_timeout: 10
      )

      assert {:ok,
              %OtelMetricExporter.OtelApi.Config{
                exporter: :otlp,
                otlp_endpoint: "http://localhost:4318",
                otlp_headers: %{"key1" => "value1", "key2" => "value2"},
                otlp_timeout: 10
              },
              %{}} =
               OtelMetricExporter.OtelApi.Config.validate_for_scope(
                 %{logs: %{exporter: :otlp}},
                 :logs
               )
    end

    test "doesn't return an error if exporter is set to :none" do
      Application.put_env(:otel_metric_exporter, :logs, exporter: :none)

      assert {:ok, %OtelMetricExporter.OtelApi.Config{exporter: :none}, %{}} =
               OtelMetricExporter.OtelApi.Config.validate_for_scope(
                 %{},
                 :logs
               )
    end
  end
end
