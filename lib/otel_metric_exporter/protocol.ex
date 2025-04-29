defmodule OtelMetricExporter.Protocol do
  @moduledoc false
  alias OtelMetricExporter.Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceRequest
  alias OtelMetricExporter.Opentelemetry.Proto.Metrics.V1.ResourceMetrics
  alias OtelMetricExporter.Opentelemetry.Proto.Metrics.V1.ScopeMetrics
  alias OtelMetricExporter.Opentelemetry.Proto.Collector.Logs.V1.ExportLogsServiceRequest
  alias OtelMetricExporter.Opentelemetry.Proto.Common.V1.AnyValue
  alias OtelMetricExporter.Opentelemetry.Proto.Common.V1.InstrumentationScope
  alias OtelMetricExporter.Opentelemetry.Proto.Common.V1.KeyValueList
  alias OtelMetricExporter.Opentelemetry.Proto.Logs.V1.LogRecord
  alias OtelMetricExporter.Opentelemetry.Proto.Logs.V1.ResourceLogs
  alias OtelMetricExporter.Opentelemetry.Proto.Logs.V1.ScopeLogs
  alias OtelMetricExporter.Opentelemetry.Proto.Logs.V1.SeverityNumber
  alias OtelMetricExporter.Opentelemetry.Proto.Resource.V1.Resource
  alias OtelMetricExporter.OtlpUtils

  @doc """
  Convert a logger event to a struct ready for protobuf encoding
  """
  @spec prepare_log_event(:logger.log_event(), term()) :: struct()
  def prepare_log_event(%{level: level, msg: msg, meta: metadata}, config) do
    time = metadata[:time] * 1000
    # {trace_id, span_id} = extract_trace_context(metadata)

    %LogRecord{
      time_unix_nano: time,
      observed_time_unix_nano: time,
      severity_number: severity_number(level),
      severity_text: Atom.to_string(level),
      body: encode_body(msg),
      attributes: metadata |> prepare_attributes(config) |> OtlpUtils.build_kv(),
      dropped_attributes_count: 0,
      flags: 0,
      # Official OTel tracing library adds these as charlists, so we need to convert them to binaries
      trace_id: Map.get(metadata, :otel_trace_id, nil) |> to_string(),
      span_id: Map.get(metadata, :otel_span_id, nil) |> to_string(),
      event_name: Map.get(metadata, :event_name, nil)
    }
  end

  defp encode_body({:string, chardata}) do
    %AnyValue{value: {:string_value, IO.chardata_to_string(chardata)}}
  end

  defp encode_body({:report, report}) do
    %AnyValue{value: {:kvlist_value, %KeyValueList{values: OtlpUtils.build_kv(report)}}}
  end

  defp encode_body({io_format, args}) do
    %AnyValue{value: {:string_value, :io_lib.format(io_format, args) |> IO.chardata_to_string()}}
  end

  defp severity_number(:debug), do: SeverityNumber.value(:SEVERITY_NUMBER_DEBUG)
  defp severity_number(:info), do: SeverityNumber.value(:SEVERITY_NUMBER_INFO)
  defp severity_number(:notice), do: SeverityNumber.value(:SEVERITY_NUMBER_INFO2)
  defp severity_number(:warning), do: SeverityNumber.value(:SEVERITY_NUMBER_WARN)
  defp severity_number(:error), do: SeverityNumber.value(:SEVERITY_NUMBER_ERROR)
  defp severity_number(:critical), do: SeverityNumber.value(:SEVERITY_NUMBER_ERROR2)
  defp severity_number(:alert), do: SeverityNumber.value(:SEVERITY_NUMBER_FATAL)
  defp severity_number(:emergency), do: SeverityNumber.value(:SEVERITY_NUMBER_FATAL4)

  defp prepare_attributes(%{crash_reason: {reason, stacktrace}} = metadata, config) do
    message = if is_exception(reason), do: Exception.message(reason), else: inspect(reason)

    type =
      case reason do
        {:nocatch, _} -> "Uncaught throw"
        {:crash, _} -> "Crash"
        :crash -> "Crash"
        reason when is_exception(reason) -> to_string(reason.__struct__)
        _ -> inspect(reason)
      end

    metadata
    |> Map.drop([:crash_reason])
    |> Map.put("exception.message", message)
    |> Map.put("exception.type", type)
    |> Map.put("exception.stacktrace", Exception.format_stacktrace(stacktrace))
    |> prepare_attributes(config)
  end

  defp prepare_attributes(metadata, %{metadata: metadata_to_keep, metadata_map: metadata_map}) do
    Enum.flat_map(metadata, fn
      {k, v} when is_binary(k) ->
        [{k, v}]

      {k, v} ->
        case Map.fetch(metadata_map, k) do
          {:ok, remapped_key} ->
            [{remapped_key, v}]

          :error ->
            if k in metadata_to_keep, do: [{k, v}], else: []
        end
    end)
  end

  def build_log_service_request(events, resource \\ %{}) do
    %ExportLogsServiceRequest{
      resource_logs: [
        %ResourceLogs{
          resource: %Resource{
            attributes: OtlpUtils.build_kv(resource)
          },
          scope_logs: [
            %ScopeLogs{
              scope: %InstrumentationScope{
                name: "otel_metric_exporter"
              },
              log_records: events
            }
          ]
        }
      ]
    }
  end

  def build_metric_service_request(metrics, resource \\ %{}) do
    %ExportMetricsServiceRequest{
      resource_metrics: [
        %ResourceMetrics{
          resource: %Resource{attributes: OtlpUtils.build_kv(resource)},
          scope_metrics: [
            %ScopeMetrics{
              scope: %InstrumentationScope{name: "otel_metric_exporter"},
              metrics: metrics
            }
          ]
        }
      ]
    }
  end
end
