# Task: Fix LogAccumulator crash on unmatched :DOWN messages

## Problem

The `LogAccumulator` GenServer (used as a `logger_olp` callback) crashes with a `FunctionClauseError` when it receives a `:DOWN` message whose ref is not present in `pending_tasks`.

## Root Cause

There are two code paths that handle task completion messages:

1. **`handle_info/2`** — processes messages delivered via the normal GenServer message loop
2. **`block_until_any_task_ready/1`** — uses a raw `receive` to consume messages from the mailbox when the process is blocking

The race condition:
- `block_until_any_task_ready` receives `{ref, result}` from a completed task and removes `ref` from `pending_tasks`
- The subsequent `:DOWN` message for that same task process arrives via `handle_info`
- The guard `is_map_key(state.pending_tasks, ref)` fails on the `:DOWN` handler
- No catch-all clause exists → `FunctionClauseError` crash

Secondary bug: `handle_info({ref, result}, state)` at line 124 says "Remove the task from the pending tasks map" but the returned state is unchanged — the ref is never actually removed.

## Fix Strategy

1. In `handle_info({ref, result}, state)`: demonitor with flush and actually remove ref from `pending_tasks`
2. In `block_until_any_task_ready`: when receiving `{ref, result}`, demonitor with flush to prevent orphaned `:DOWN`
3. Add a catch-all `handle_info` clause to silently ignore any stray `:DOWN` or task result messages
4. Add a test that exercises the crash scenario
