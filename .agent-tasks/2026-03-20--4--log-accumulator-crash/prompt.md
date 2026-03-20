# Task prompt

Assigned issue: electric-sql/alco-agent-tasks#4
Upstream issue: electric-sql/elixir-otel-metric-exporter#18

**Title:** When export fails repeatedly due to the remote server being unavailable, LogAccumulator crashes hard

**Description:** Investigate and implement a fix for the LogAccumulator crashing with `FunctionClauseError` when it receives `:DOWN` messages from export tasks that it no longer tracks in `pending_tasks`.
