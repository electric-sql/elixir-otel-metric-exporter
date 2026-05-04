# Task: Investigate Distribution Metric Reporting

## Problem Statement

The `telemetry_metrics.distribution` metric is reported to Honeycomb (via OTLP export) with:
- `min` and `max` always showing as 0
- Percentiles (p01, p50, p99, etc.) not matching actual values
- Only `avg` and `sum` appearing to be correct

## Reported Symptoms

Example 1 (single data point, value ~668):
- avg=668, sum=668, count=1
- min=0, max=0
- All percentiles show 500

Example 2 (two data points, values ~714 and ~1000):
- avg=857, sum=1714, count=2
- min=0, max=0
- Lower percentiles=500, higher percentiles=1000

## Investigation Approach

1. Write unit tests that exercise the full distribution metric pipeline: write → aggregate → export
2. Verify the exported HistogramDataPoint protobuf structure
3. Confirm whether min/max fields are populated
4. Confirm whether `round(value)` causes precision loss
5. Document whether percentile behavior is expected (bucket-based limitation) vs a bug
