# Progress log

## Timeline

- **2026-03-20 Start**: Claimed task, read issue #18 and LogAccumulator source code
- **2026-03-20**: Identified root cause — race between `block_until_any_task_ready` consuming `{ref, result}` and subsequent `:DOWN` arriving via `handle_info` with ref already removed from `pending_tasks`
- **2026-03-20**: Also found secondary bug — `handle_info({ref, result}, state)` doesn't actually remove ref from `pending_tasks` despite the comment

## Operational issues

(none so far)
