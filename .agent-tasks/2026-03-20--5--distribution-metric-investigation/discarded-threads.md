# Discarded Threads

## Considered: Testing with actual Honeycomb export

Considered setting up an integration test that exports to a mock OTLP endpoint and verifies the full proto payload. Decided this is overkill for an investigation — the unit tests on `convert_data/2` output are sufficient to confirm the issues at the exporter level. The percentile display is a Honeycomb-side concern.
