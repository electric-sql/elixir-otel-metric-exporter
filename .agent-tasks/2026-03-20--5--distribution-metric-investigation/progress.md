# Progress Log

## 2026-03-20

### Initial analysis

- Read the upstream issue (electric-sql/elixir-otel-metric-exporter#20)
- Analyzed the full distribution metric pipeline in the codebase
- Identified root causes (see findings below)

### Code analysis findings

1. **Min/Max never populated**: The `HistogramDataPoint` proto has optional `min` (field 11) and `max` (field 12) fields, but `convert_data/2` for `%Metrics.Distribution{}` never sets them. The ETS storage only tracks `{count, sum}` per bucket — individual min/max values are not tracked during `write_metric/5`.

2. **Values rounded to integers**: `write_metric/5` uses `round(value)` in `update_sum_op = {3, round(value)}` (line 107 of metric_store.ex). This means fractional values are truncated. For a value of 668.7, the sum would record 669.

3. **Percentiles are a receiver-side interpretation**: The exporter sends standard OTLP histogram data (bucket_counts + explicit_bounds). Honeycomb estimates percentiles from these bucket boundaries. With default buckets `[0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, ...]`, a value of 668 falls in the (500, 750] bucket. Honeycomb estimates percentiles as 500 (lower bound) since it can't know the actual value within the bucket.

### Writing tests

- Created `test/otel_metric_exporter/distribution_investigation_test.exs` with tests that:
  - Confirm min/max are nil in exported HistogramDataPoint
  - Confirm values are rounded (precision loss)
  - Verify bucket assignment correctness
  - Exercise the scenario from the original issue

### Operational issues

(none so far)
