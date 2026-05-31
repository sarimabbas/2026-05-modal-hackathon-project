# 2026-05-modal-hackathon-project

## Setup

```
make install
```

## Human computer usage tracing prototype

This repo includes a local-only macOS prototype that turns computer usage into Raindrop Workshop traces.

Run Workshop first, then:

```bash
make human-trace
```

The script captures metadata by default:

- active app and focused window title
- clicks and click coordinates
- scroll deltas
- aggregate key-down counts
- coarse mouse movement counts

It deliberately does **not** capture typed text, screenshots, clipboard contents, or file contents by default. macOS may prompt for Accessibility/Input Monitoring permissions; grant them, then rerun the command.

Screenshots are on by default for clicks and non-trivial keyboard bursts. Disable them with:

```bash
make human-trace-no-screenshots
# or
HUMAN_TRACE_SCREENSHOTS=0 make human-trace
```

Screenshots require macOS Screen Recording permission and may contain sensitive information.

Each Workshop sidebar item is one activity burst. A new burst starts after an idle gap, configurable with:

```bash
HUMAN_TRACE_SEGMENT_IDLE_SECONDS=10 make human-trace
```

Menu bar recorder:

```bash
make human-trace-menu
```

Look for `HT` in the macOS menu bar. Use the menu to start/stop recording, toggle screenshots, choose the idle segmentation threshold, toggle typed-text capture, or open Workshop. While recording the icon changes to `● HT`.

Typed-text capture is off by default because it can capture secrets. If you enable `Capture Typed Text`, continuous typing is compacted into `typing burst` spans with `keyboard.typed_text` metadata.

Open Workshop:

```bash
make human-trace-open-workshop
```

## Mochi Rewind web app

Mochi is a cute local rewind viewer for human traces in `~/.raindrop/raindrop_workshop.db`.

```bash
npm install
npm run dev
```

Open the Vite URL, usually `http://127.0.0.1:5173`. The API runs on `http://127.0.0.1:4317` with permissive CORS and polls SQLite. Screenshots are served from `~/.raindrop/human-trace-screenshots`.

The UI is intentionally simple: screenshots in the center, a horizontally scrollable annotated timeline on the bottom, and search on top. Search uses a local SQLite FTS5 sidecar table (`rewind_search`) over span names, app/window metadata, typed text, UI accessibility metadata, tool-call fields, screenshot paths, and run metadata.

## Replay toolkit

Agents can use the local replay toolkit without opening the web UI:

```bash
node scripts/replay.mjs search "excalidraw pelican"
node scripts/replay.mjs search "excalidraw" --since-minutes 10
node scripts/replay.mjs plan latest --since-minutes 10
node scripts/replay.mjs run-plan latest --since-minutes 10 --dry-run --limit 20
node scripts/replay.mjs span <span_id>
node scripts/replay.mjs prune --since-minutes 15
node scripts/replay.mjs inspect
node scripts/replay.mjs act click 640 420
node scripts/replay.mjs act drag 200 300 460 360 450
node scripts/replay.mjs act scroll 0 -900 640 420
node scripts/replay.mjs act type "hello"
node scripts/replay.mjs screenshot
node scripts/replay.mjs bench-suite latest --query "excalidraw pelican" --since-minutes 10 --native-ms 120000
npm run replay:server
raindrop replay register
```

The Swift actuator (`scripts/ReplayTool.swift`) uses macOS CGEvent plus Accessibility inspection. The Node wrapper searches the same Workshop SQLite data as Mochi Rewind and turns human traces into replay plans. `--since-minutes 10` is the demo-friendly history filter: it leaves old data alone but makes agents search and plan only over the fresh recording window. `node scripts/replay.mjs prune --since-minutes 15` is the stronger demo reset: it deletes older `human_computer_use` spans/screenshots and cleans stale FTS rows while leaving other Workshop event families alone. `span <span_id>` returns the replay fields and any recorded screenshot file path for visual checking. New menu bar traces include replay-oriented metadata: action sequence, normalized coordinates, display/window frames, AX targets, drag bursts, key modifier histograms, and screenshot check points.

Workshop-native replay is registered through `.raindrop/agents.yaml` and served by `scripts/replay-server.mjs` on port `61020`. It defaults to dry-run planning for safety; set replay context `execute: true` to perform macOS actions.

Benchmark loop:

1. Record a human demo with `make human-trace-menu`.
2. Find the trace with `node scripts/replay.mjs search "<task words>"`.
3. Build a replay plan with `node scripts/replay.mjs plan <run_id>`.
4. Execute with `node scripts/replay.mjs act ...`, checking progress with `inspect` and `screenshot`.
5. Run `node scripts/replay.mjs bench-suite <run_id> --native-ms <native_wall_clock_ms>`. The target is `toolkit_time <= native_time / 2`; missing or slow steps should become new recorder fields or replay commands.

Benchmark reports append to `.raindrop/benchmarks/computer-use-replay-benchmarks.jsonl` by default. Each line records search, plan, dry-run replay timings, executable action ratio, speedup, pass/fail, and bottleneck hints.

## Raindrop Workshop MCP

Workshop includes a local MCP server:

```bash
raindrop workshop mcp
```

It is a strong fit for the agent toolkit because it exposes the Workshop trace database directly: current-run lookup, read-only SQL trace queries, run outlines, run search, span payload reads, annotations, UI navigation, captured-agent Q&A, and `replay_run` for registered local replay servers.

For Codex, add this MCP server to the agent config:

```toml
[mcp_servers.raindrop]
command = "/Users/sarimabbas/.raindrop/bin/raindrop"
args = ["workshop", "mcp"]
startup_timeout_sec = 30
```

This complements `scripts/replay.mjs`: use Raindrop MCP for trace inspection and Workshop-native replay, and use `scripts/replay.mjs` for low-level macOS computer-use actions.

## Repo-local agent skill

The replay workflow is packaged as a Codex skill in `skills/computer-use-replay/SKILL.md`. Use `$computer-use-replay` when asking an agent to search traces, build or execute replay plans, improve recorder metadata, or benchmark against native computer-use.
