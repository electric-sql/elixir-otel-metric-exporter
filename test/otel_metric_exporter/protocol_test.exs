defmodule OtelMetricExporter.ProtocolTest do
  use ExUnit.Case, async: true

  alias OtelMetricExporter.Protocol

  @config %{
    metadata: [:request_id, :stack_id, :span_id],
    metadata_map: %{request_id: "http.request.id"}
  }

  describe "build_log_service_request" do
    test "correctly encodes report messages" do
      events = [
        Protocol.prepare_log_event(
          %{
            level: :info,
            msg: {:report, request_id: "req-aaaa", stack_id: "stack-aaaa"},
            meta: %{time: System.system_time(:millisecond)}
          },
          @config
        )
      ]

      msg =
        Protocol.build_log_service_request(events)
        |> Protox.encode!()
        |> then(fn {iodata, _size} -> IO.iodata_to_binary(iodata) end)

      assert is_binary(msg)
    end
  end
end
