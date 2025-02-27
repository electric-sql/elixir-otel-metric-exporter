defmodule OtelMetricExporter.Opentelemetry.Proto.Collector.Logs.V1.ExportLogsServiceRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field(:resource_logs, 1,
    repeated: true,
    type: OtelMetricExporter.Opentelemetry.Proto.Logs.V1.ResourceLogs,
    json_name: "resourceLogs"
  )
end

defmodule OtelMetricExporter.Opentelemetry.Proto.Collector.Logs.V1.ExportLogsServiceResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field(:partial_success, 1,
    type: OtelMetricExporter.Opentelemetry.Proto.Collector.Logs.V1.ExportLogsPartialSuccess,
    json_name: "partialSuccess"
  )
end

defmodule OtelMetricExporter.Opentelemetry.Proto.Collector.Logs.V1.ExportLogsPartialSuccess do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field(:rejected_log_records, 1, type: :int64, json_name: "rejectedLogRecords")
  field(:error_message, 2, type: :string, json_name: "errorMessage")
end
