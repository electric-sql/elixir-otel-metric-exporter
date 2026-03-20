# Implementation Plan

## Step 1: Fix task result handler to properly clean up

In `handle_info({ref, result}, state)` (line 124-134):
- Call `Process.demonitor(ref, [:flush])` to prevent the `:DOWN` message from arriving
- Actually remove the ref from `pending_tasks` (the current code has a comment but doesn't do it)

## Step 2: Fix `block_until_any_task_ready` to demonitor on result receipt

When the `receive` block in `block_until_any_task_ready` catches `{ref, _result}`:
- Call `Process.demonitor(ref, [:flush])` to prevent orphaned `:DOWN` messages

## Step 3: Add catch-all `handle_info` clause

Add a catch-all at the bottom of the `handle_info` clauses that silently ignores any unexpected messages. This is a safety net for any edge cases we haven't anticipated.

## Step 4: Add test for the crash scenario

Write a test that:
- Sets up a LogAccumulator with concurrent request limit of 1
- Sends enough logs to trigger `block_until_any_task_ready`
- Makes the export endpoint unavailable so tasks fail
- Verifies the LogAccumulator doesn't crash

---

## Review discussion

**Reviewer concern:** Adding a catch-all `handle_info` could hide future bugs.

**Response:** Since this module uses `@behaviour GenServer` and is used as a `logger_olp` callback, unexpected messages are a real possibility (e.g., `:EXIT` from `trap_exit`, or stray messages from the OTP logger framework). The catch-all only applies after all specific handlers have been tried. The `:DOWN` and task result message types are well-understood, and the catch-all acts as a safety net.

**Reviewer concern:** Should we log stray messages?

**Response:** No — logging from inside a log handler risks recursion. Silent discard is the correct behavior here.
