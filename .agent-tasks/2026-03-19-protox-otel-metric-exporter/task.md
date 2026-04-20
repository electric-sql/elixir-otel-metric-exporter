# Task: Replace protobuf with protox in otel_metric_exporter

## Background
The `otel_metric_exporter` library currently depends on `protobuf` (elixir-protobuf/protobuf) for encoding/decoding OpenTelemetry protobuf messages. This creates a version pin issue in dependent projects (electric/stratovolt). See https://github.com/electric-sql/electric/issues/4018.

## Goal
Replace the `protobuf` dependency with `protox` (https://github.com/ahamez/protox), a pure-Elixir Protocol Buffers library that doesn't require pinning specific versions.

## Scope
1. Replace `{:protobuf, "~> 0.15"}` with `{:protox, "~> ..."}` in mix.exs
2. Rewrite all `.pb.ex` files (6 files under `lib/otel_metric_exporter/opentelemetry/proto/`) to use protox-style module definitions
3. Update all call sites that use `Protobuf.encode_to_iodata/1`, `Protobuf.decode/2`, and enum `value/1` functions
4. Ensure all tests pass
5. Bump the library version appropriately

## Key files using protobuf
- `lib/otel_metric_exporter/otel_api.ex` - `Protobuf.encode_to_iodata/1` and `Protobuf.EncodeError`
- `lib/otel_metric_exporter/protocol.ex` - `SeverityNumber.value/1` for enum mapping
- `lib/otel_metric_exporter/metric_store.ex` - `ExportMetricsServiceRequest.decode/1` (in tests via the module)
- Test files - `Protobuf.decode/2` calls for decoding responses
- 6 `.pb.ex` files - protobuf message definitions using `use Protobuf`
