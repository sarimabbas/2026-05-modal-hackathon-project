---
name: computer-use-replay
description: Build and use the local computer-use replay toolkit for Raindrop Workshop human traces. Use when asked to search recorded computer activity, inspect or replay traces, drive macOS with click/scroll/type/drag actions, compare against native computer-use speed, improve replay trace fields, or integrate Raindrop Workshop MCP with this repo's agent tooling.
---

# Computer Use Replay

## Overview

Use this skill to work on the repo-local augmented computer-use toolkit. The system has three layers:

- Recorder: `scripts/HumanTraceMenuBar.swift` records human computer-use spans into Raindrop Workshop.
- Replay actuator: `scripts/ReplayTool.swift` performs macOS actions and Accessibility inspection.
- Agent wrapper/API: `scripts/replay.mjs` and `server/api.mjs` search traces, build replay plans, expose APIs, and benchmark speed.
- Workshop replay server: `scripts/replay-server.mjs` implements `GET /health` and `POST /replay` for `.raindrop/agents.yaml`.

Treat the worktree as shared. Inspect current files before editing, keep changes scoped, and avoid broad frontend or recorder rewrites unless the task specifically requires them.

## Workflow

1. Confirm Workshop and repo state.

```bash
raindrop workshop status
git status --short
node --check scripts/replay.mjs
node --check server/api.mjs
swiftc -typecheck scripts/ReplayTool.swift
swiftc -typecheck scripts/HumanTraceMenuBar.swift
```

2. Search traces or find a run.

```bash
node scripts/replay.mjs search "task words"
curl -fsS "http://127.0.0.1:4317/api/replay/search?q=task%20words&limit=5"
```

Prefer Raindrop MCP for Workshop-native trace inspection when available:

- `get_current_run` for the run on screen.
- `get_run_outline` before reading payloads.
- `search_run` for targeted text search inside one run.
- `query_traces` for read-only SQLite discovery.
- `get_span_payload` only for exact raw evidence.
- `replay_run` for Workshop-native replay against registered local replay servers.

3. Build a replay plan.

```bash
node scripts/replay.mjs plan <run_id>
curl -fsS "http://127.0.0.1:4317/api/replay/run/<run_id>/plan"
```

Plans should include action, coordinates, target AX metadata, app/window context, screenshots/checkpoints where available, and timing hints.

4. Execute or test actions.

Use `--dry-run` before touching the UI:

```bash
node scripts/replay.mjs run-plan <run_id> --dry-run --limit 10
node scripts/replay.mjs run-plan <run_id> --limit 10 --delay-ms 120 --check-every 3
```

Use individual actions for debugging:

```bash
node scripts/replay.mjs inspect
node scripts/replay.mjs screenshot
node scripts/replay.mjs act click 640 420
node scripts/replay.mjs act drag 200 300 460 360 450
node scripts/replay.mjs act scroll 0 -900 640 420
node scripts/replay.mjs act type "hello"
```

Do not run destructive UI actions without a clear user request or a safe target app.

5. Benchmark.

```bash
node scripts/replay.mjs bench <run_id> --native-ms <native_wall_clock_ms>
node scripts/replay.mjs bench-suite <run_id> --query "task words" --native-ms <native_wall_clock_ms>
```

Prefer `bench-suite` for the virtuous loop. It appends JSONL reports to `.raindrop/benchmarks/computer-use-replay-benchmarks.jsonl` with search, plan, dry-run replay timings, executable action ratio, speedup, pass/fail, and bottleneck hints.

The target is `native_wall_clock_ms / toolkit_wall_clock_ms >= 2`. If it fails, improve the highest-cost missing capability: richer recorder metadata, faster search/planning, better target resolution, fewer screen checks, or a more direct action primitive.

## Recorder Changes

When enriching `scripts/HumanTraceMenuBar.swift`, preserve privacy defaults:

- Do not capture clipboard contents or file contents.
- Keep typed text opt-in.
- Prefer focused-window screenshots over full-screen screenshots.
- Do not capture the Mochi/Rewind viewer itself.

Useful trace fields for replay:

- `trace.schema_version`, `trace.sequence`, `trace.observed_at_ms`.
- `replay.action`, `replay.kind`, `replay.primary_x`, `replay.primary_y`, `replay.target`.
- App/window fields: `app.name`, `app.bundle`, `window.title`, window frame.
- AX fields: role, title/value/description/help, identifier, enabled/focused, frame, ancestry.
- Action fields: click button/count, scroll dx/dy, drag start/end/duration/distance, key code/modifier histograms.
- Screenshot fields: `screenshot.attached`, `screenshot.capture`, `screenshot.name`, `screenshot.path`.

After recorder edits, run:

```bash
swiftc -typecheck scripts/HumanTraceMenuBar.swift
```

## API And CLI Changes

Keep `scripts/replay.mjs` and `server/api.mjs` aligned. If replay action extraction changes in one, update the other.

Important endpoints:

- `GET /api/replay/search?q=<query>&limit=<n>`
- `GET /api/replay/run/:id/plan`
- `GET /api/replay/span/:id`

Important CLI commands:

- `search`: local SQLite FTS over human traces.
- `plan`: convert a run into replay actions.
- `run-plan`: execute a whole plan with dry-run, limit, delay, and check controls.
- `act`: low-level macOS action passthrough.
- `inspect` and `screenshot`: check work.
- `bench`: measure toolkit overhead and compare to native baseline.
- `bench-suite`: repeatable search/plan/dry-run benchmark that records JSONL history and bottlenecks.

After CLI/API edits, run:

```bash
node --check scripts/replay.mjs
node --check server/api.mjs
npm run build
```

## Raindrop MCP

The local Workshop MCP server is:

```bash
raindrop workshop mcp
```

Codex config entry:

```toml
[mcp_servers.raindrop]
command = "/Users/sarimabbas/.raindrop/bin/raindrop"
args = ["workshop", "mcp"]
startup_timeout_sec = 30
```

Use MCP for trace/database inspection and Workshop-native replay. Use `scripts/replay.mjs` for repo-local action execution and benchmark experiments.

The repo also registers a local replay server:

```bash
npm run replay:server
raindrop replay register
```

The server listens on port `61020`, uses event name `human_computer_use`, and defaults to dry-run planning. It only performs macOS actions when replay context includes `execute: true`.

## Validation

Minimum validation for most changes:

```bash
node --check scripts/replay.mjs
node --check server/api.mjs
swiftc -typecheck scripts/ReplayTool.swift
swiftc -typecheck scripts/HumanTraceMenuBar.swift
```

For non-destructive runtime validation:

```bash
node scripts/replay.mjs search human
node scripts/replay.mjs run-plan <run_id> --dry-run --limit 5
node scripts/replay.mjs bench-suite <run_id> --native-ms 2000 --limit 5
```

Avoid broad Accessibility dumps in final answers; they can expose visible terminal or app contents from other sessions.
