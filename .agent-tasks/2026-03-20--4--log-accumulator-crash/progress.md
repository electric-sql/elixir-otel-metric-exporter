# Progress log

## Timeline

- **2026-03-20 Start**: Claimed task, read issue #18 and LogAccumulator source code
- **2026-03-20**: Identified root cause — race between `block_until_any_task_ready` consuming `{ref, result}` and subsequent `:DOWN` arriving via `handle_info` with ref already removed from `pending_tasks`
- **2026-03-20**: Also found secondary bug — `handle_info({ref, result}, state)` doesn't actually remove ref from `pending_tasks` despite the comment
- **2026-03-20**: Implemented fix with 3 changes: proper demonitor+cleanup in handle_info, demonitor+flush in block_until_any_task_ready, and catch-all handle_info clause
- **2026-03-20**: Added integration test, all 45 tests pass
- **2026-03-20**: Opened PR https://github.com/electric-sql/elixir-otel-metric-exporter/pull/31

## Operational issues

- Had to run `mix deps.get` to download `protobuf` dependency before tests would run
- Test design required careful handling of the feedback loop: failed exports generate Logger.debug logs which themselves get queued as log events, causing cascading export attempts. Used `retry: false` config and `Bypass.stub` (not `expect_once`) to handle this gracefully
