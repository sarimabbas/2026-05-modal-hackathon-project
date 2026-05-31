#!/usr/bin/env node
import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dbPath = process.env.RAINDROP_WORKSHOP_DB ?? path.join(os.homedir(), '.raindrop', 'raindrop_workshop.db');
const swiftTool = path.join(root, 'scripts', 'ReplayTool.swift');
const recordedScreenshotDir = process.env.HUMAN_TRACE_SCREENSHOT_DIR ?? path.join(os.homedir(), '.raindrop', 'human-trace-screenshots');
const replayScreenshotDir = process.env.HUMAN_REPLAY_SCREENSHOT_DIR ?? path.join(os.homedir(), '.raindrop', 'human-trace-replay');
const benchmarkDir = path.join(root, '.raindrop', 'benchmarks');

const args = process.argv.slice(2);
const command = args.shift();

if (!command || ['-h', '--help', 'help'].includes(command)) usage();

try {
  if (command === 'search') {
    const { positional, flags } = parseFlags(args);
    const q = positional.join(' ').trim();
    if (!q) usage();
    print(await search(q, {
      limit: Number(flags.limit ?? process.env.REPLAY_LIMIT ?? 20),
      sinceMinutes: recentMinutesFromFlags(flags),
    }));
  } else if (command === 'plan') {
    const { positional, flags } = parseFlags(args);
    const runId = await resolveRunId(positional[0], recentMinutesFromFlags(flags), { requireActions: true });
    if (!runId) usage();
    print(await plan(runId, { sinceMinutes: recentMinutesFromFlags(flags) }));
  } else if (command === 'run-plan') {
    print(await runPlan(args));
  } else if (command === 'rebuild-index') {
    const { flags } = parseFlags(args);
    print({ ok: true, indexed: await rebuildSearchIndex({ sinceMinutes: recentMinutesFromFlags(flags) ?? 120 }) });
  } else if (command === 'prune') {
    const { flags } = parseFlags(args);
    const hours = Number(flags.hours ?? (recentMinutesFromFlags(flags) ? recentMinutesFromFlags(flags) / 60 : 0.25));
    print({ ok: true, ...(await pruneHumanTraceData({ hours })) });
  } else if (command === 'span') {
    const spanId = args[0];
    if (!spanId) usage();
    print(await span(spanId));
  } else if (command === 'act') {
    await act(args);
  } else if (command === 'inspect') {
    print(await swift(['inspect', ...args]));
  } else if (command === 'screenshot') {
    const out = args[0] ?? path.join(replayScreenshotDir, `check-${Date.now()}.png`);
    print(await swift(['screenshot', out]));
  } else if (command === 'bench') {
    print(await bench(args));
  } else if (command === 'bench-suite') {
    print(await benchSuite(args));
  } else {
    usage();
  }
} catch (err) {
  console.error(err.message);
  process.exit(1);
}

function usage() {
  console.error(`Usage:
  node scripts/replay.mjs search <query>
  node scripts/replay.mjs search <query> [--since-minutes <n>] [--limit <n>]
  node scripts/replay.mjs plan <run_id|latest> [--since-minutes <n>]
  node scripts/replay.mjs run-plan <run_id|latest> [--dry-run] [--limit <n>] [--delay-ms <ms>] [--check-every <n>] [--since-minutes <n>]
  node scripts/replay.mjs span <span_id>
  node scripts/replay.mjs rebuild-index
  node scripts/replay.mjs prune [--hours <n>|--since-minutes <n>]
  node scripts/replay.mjs act click <x> <y> [left|right]
  node scripts/replay.mjs act scroll <dx> <dy> [x y]
  node scripts/replay.mjs act drag <x1> <y1> <x2> <y2> [durationMs]
  node scripts/replay.mjs act type <text>
  node scripts/replay.mjs act paste <text>
  node scripts/replay.mjs inspect [x y]
  node scripts/replay.mjs screenshot [path]
  node scripts/replay.mjs bench [run_id] [--native-ms <ms>]
  node scripts/replay.mjs bench-suite [run_id] [--query <q>] [--native-ms <ms>] [--limit <n>] [--since-minutes <n>] [--output <path>]
`);
  process.exit(2);
}

async function sqlite(query, params = []) {
  if (!existsSync(dbPath)) throw new Error(`Workshop DB not found: ${dbPath}`);
  const { stdout } = await execFileAsync('sqlite3', ['-cmd', '.timeout 5000', '-json', dbPath, bindSql(query, params)], { maxBuffer: 80 * 1024 * 1024 });
  return stdout.trim() ? JSON.parse(stdout) : [];
}

async function execSql(script) {
  if (!existsSync(dbPath)) throw new Error(`Workshop DB not found: ${dbPath}`);
  await execFileAsync('sqlite3', ['-cmd', '.timeout 5000', dbPath, script], { maxBuffer: 80 * 1024 * 1024 });
}

function isHumanTraceScreenshotName(file) {
  return /^(click|typing|drag)_burst-\d+\.png$/.test(file);
}

function parseJson(value, fallback = {}) {
  if (!value) return fallback;
  try { return JSON.parse(value); } catch { return fallback; }
}

function sqliteString(value) {
  return `'${String(value ?? '').replaceAll("'", "''")}'`;
}

function bindSql(query, params = []) {
  let index = 0;
  return query.replace(/\?/g, () => {
    if (index >= params.length) throw new Error('missing SQL parameter');
    return sqliteString(params[index++]);
  });
}

function escapeFts(query) {
  return query.trim().split(/\s+/).filter(Boolean).map((term) => `"${term.replaceAll('"', '""')}"`).join(' AND ');
}

async function rebuildSearchIndex({ sinceMinutes = null } = {}) {
  await execSql(`
    CREATE VIRTUAL TABLE IF NOT EXISTS rewind_search USING fts5(
      run_id UNINDEXED,
      span_id UNINDEXED,
      kind UNINDEXED,
      title,
      content,
      tokenize='porter unicode61'
    );
    DELETE FROM rewind_search;
  `);
  const rows = await sqlite(`
    SELECT r.id AS run_id, s.id AS span_id, r.event_name, r.name AS run_name,
           substr(COALESCE(r.metadata, ''), 1, 1000) AS run_metadata,
           s.name AS span_name, s.span_type,
           substr(COALESCE(s.input_payload, ''), 1, 1000) AS input_payload,
           substr(COALESCE(s.output_payload, ''), 1, 1000) AS output_payload,
           substr(COALESCE(s.attributes, ''), 1, 5000) AS attributes
    FROM spans s JOIN runs r ON r.id = s.run_id
    WHERE r.event_name = 'human_computer_use'
      ${recentSpanWhere('s', sinceMinutes)}
    ORDER BY s.start_time_ms ASC
  `);
  const tuples = rows.map((row) => {
    const a = parseJson(row.attributes);
    const text = [
      row.run_name, row.event_name, row.span_name, row.span_type, row.input_payload, row.output_payload,
      a['app.name'], a['app.bundle'], a['window.title'], a['keyboard.typed_text'],
      a['replay.action'], a['replay.kind'], a['replay.target'],
      a['ui.first.role'], a['ui.first.title'], a['ui.first.value'], a['ui.first.description'], a['ui.first.identifier'], a['ui.first.ancestry'],
      a['ui.last.role'], a['ui.last.title'], a['ui.last.value'], a['ui.last.description'], a['ui.last.identifier'], a['ui.last.ancestry'],
      a['ai.toolCall.name'], a['ai.toolCall.args'], a['ai.toolCall.result'],
      a['screenshot.name'], a['screenshot.path'], row.run_metadata,
    ].filter(Boolean).join('\n').slice(0, 4000);
    const values = [row.run_id, row.span_id, classify(a, row), row.span_name ?? '', text].map(sqliteString);
    return `(${values.join(',')})`;
  });
  for (let i = 0; i < tuples.length; i += 25) {
    const chunk = tuples.slice(i, i + 25);
    if (chunk.length) await execSql(`INSERT INTO rewind_search(run_id, span_id, kind, title, content) VALUES ${chunk.join(',')};`);
  }
  await execSql(`CREATE TABLE IF NOT EXISTS rewind_search_meta(key TEXT PRIMARY KEY, value TEXT); INSERT OR REPLACE INTO rewind_search_meta(key, value) VALUES ('last_full_rebuild_ms', '${Date.now()}');`);
  await execSql(`
    CREATE TABLE IF NOT EXISTS rewind_search_indexed_spans(span_id TEXT PRIMARY KEY, run_id TEXT);
    DELETE FROM rewind_search_indexed_spans;
    INSERT OR IGNORE INTO rewind_search_indexed_spans(span_id, run_id) SELECT span_id, run_id FROM rewind_search;
  `);
  return rows.length;
}

async function ensureSearchIndex() {
  await execSql(`
    CREATE VIRTUAL TABLE IF NOT EXISTS rewind_search USING fts5(
      run_id UNINDEXED,
      span_id UNINDEXED,
      kind UNINDEXED,
      title,
      content,
      tokenize='porter unicode61'
    );
    CREATE TABLE IF NOT EXISTS rewind_search_meta(key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE IF NOT EXISTS rewind_search_indexed_spans(span_id TEXT PRIMARY KEY, run_id TEXT);
    INSERT OR IGNORE INTO rewind_search_indexed_spans(span_id, run_id) SELECT span_id, run_id FROM rewind_search;
  `);
  const rows = await sqlite(`
    SELECT r.id AS run_id, s.id AS span_id, r.event_name, r.name AS run_name,
           substr(COALESCE(r.metadata, ''), 1, 1000) AS run_metadata,
           s.name AS span_name, s.span_type,
           substr(COALESCE(s.input_payload, ''), 1, 1000) AS input_payload,
           substr(COALESCE(s.output_payload, ''), 1, 1000) AS output_payload,
           substr(COALESCE(s.attributes, ''), 1, 5000) AS attributes
    FROM spans s JOIN runs r ON r.id = s.run_id
    WHERE r.event_name = 'human_computer_use'
      AND NOT EXISTS (SELECT 1 FROM rewind_search_indexed_spans ix WHERE ix.span_id = s.id)
    ORDER BY s.start_time_ms ASC
    LIMIT 1000
  `);
  await insertSearchRows(rows);
  await execSql(`INSERT OR REPLACE INTO rewind_search_meta(key, value) VALUES ('last_incremental_ms', '${Date.now()}'), ('last_incremental_count', '${rows.length}');`);
  return rows.length;
}

async function insertSearchRows(rows) {
  const tuples = rows.map((row) => {
    const a = parseJson(row.attributes);
    const text = [
      row.run_name, row.event_name, row.span_name, row.span_type, row.input_payload, row.output_payload,
      a['app.name'], a['app.bundle'], a['window.title'], a['keyboard.typed_text'],
      a['replay.action'], a['replay.kind'], a['replay.target'],
      a['ui.first.role'], a['ui.first.title'], a['ui.first.value'], a['ui.first.description'], a['ui.first.identifier'], a['ui.first.ancestry'],
      a['ui.last.role'], a['ui.last.title'], a['ui.last.value'], a['ui.last.description'], a['ui.last.identifier'], a['ui.last.ancestry'],
      a['ai.toolCall.name'], a['ai.toolCall.args'], a['ai.toolCall.result'],
      a['screenshot.name'], a['screenshot.path'], row.run_metadata,
    ].filter(Boolean).join('\n').slice(0, 4000);
    const values = [row.run_id, row.span_id, classify(a, row), row.span_name ?? '', text].map(sqliteString);
    return `(${values.join(',')})`;
  });
  for (let i = 0; i < tuples.length; i += 50) {
    const chunk = tuples.slice(i, i + 50);
    if (chunk.length) await execSql(`INSERT INTO rewind_search(run_id, span_id, kind, title, content) VALUES ${chunk.join(',')};`);
  }
  if (rows.length) {
    const indexed = rows.map((row) => `(${sqliteString(row.span_id)},${sqliteString(row.run_id)})`);
    for (let i = 0; i < indexed.length; i += 200) {
      const chunk = indexed.slice(i, i + 200);
      await execSql(`INSERT OR IGNORE INTO rewind_search_indexed_spans(span_id, run_id) VALUES ${chunk.join(',')};`);
    }
  }
}

async function screenshotNamesForPrune(cutoffMs) {
  const rows = await sqlite(`
    SELECT s.attributes
    FROM spans s JOIN runs r ON r.id = s.run_id
    WHERE r.event_name = 'human_computer_use'
      AND COALESCE(s.start_time_ms, r.started_at) < ${Math.floor(cutoffMs)}
      AND s.attributes LIKE '%screenshot%'
  `);
  return new Set(rows.map((row) => {
    const a = parseJson(row.attributes, {});
    return a['screenshot.name'] || (a['screenshot.path'] ? path.basename(a['screenshot.path']) : '');
  }).filter(Boolean));
}

async function pruneSearchRows(runIds = []) {
  const runClause = runIds.length ? `
    DELETE FROM rewind_search WHERE run_id IN (${runIds.map(sqliteString).join(',')});
    DELETE FROM rewind_search_indexed_spans WHERE run_id IN (${runIds.map(sqliteString).join(',')});
  ` : '';
  await execSql(`
    CREATE VIRTUAL TABLE IF NOT EXISTS rewind_search USING fts5(
      run_id UNINDEXED,
      span_id UNINDEXED,
      kind UNINDEXED,
      title,
      content,
      tokenize='porter unicode61'
    );
    CREATE TABLE IF NOT EXISTS rewind_search_indexed_spans(span_id TEXT PRIMARY KEY, run_id TEXT);
    ${runClause}
    DELETE FROM rewind_search WHERE span_id NOT IN (SELECT id FROM spans);
    DELETE FROM rewind_search_indexed_spans WHERE span_id NOT IN (SELECT id FROM spans);
  `);
}

async function pruneHumanTraceData({ hours = 0.25 } = {}) {
  const safeHours = Math.max(0.05, Math.min(Number(hours) || 0.25, 168));
  const cutoffMs = Date.now() - safeHours * 60 * 60 * 1000;
  const oldRunRows = await sqlite(`
    SELECT r.id
    FROM runs r
    WHERE r.event_name = 'human_computer_use'
      AND (
        COALESCE(r.last_updated_at, r.started_at) < ${Math.floor(cutoffMs)}
        OR NOT EXISTS (
          SELECT 1 FROM spans s
          WHERE s.run_id = r.id AND COALESCE(s.start_time_ms, r.started_at) >= ${Math.floor(cutoffMs)}
        )
      )
  `);
  const oldRunIds = oldRunRows.map((row) => row.id).filter(Boolean);
  const oldRunList = oldRunIds.map(sqliteString).join(',');
  const shotNames = await screenshotNamesForPrune(cutoffMs);

  const [oldSpanCount] = await sqlite(`
    SELECT COUNT(*) AS count
    FROM spans s JOIN runs r ON r.id = s.run_id
    WHERE r.event_name = 'human_computer_use'
      AND COALESCE(s.start_time_ms, r.started_at) < ${Math.floor(cutoffMs)}
  `);
  await execSql(`
    DELETE FROM spans
    WHERE id IN (
      SELECT s.id
      FROM spans s JOIN runs r ON r.id = s.run_id
      WHERE r.event_name = 'human_computer_use'
        AND COALESCE(s.start_time_ms, r.started_at) < ${Math.floor(cutoffMs)}
    );
  `);

  let deletedRuns = 0;
  if (oldRunIds.length) {
    const [runCount] = await sqlite(`SELECT COUNT(*) AS count FROM runs WHERE id IN (${oldRunList})`);
    deletedRuns = Number(runCount?.count ?? 0);
    await execSql(`
      DELETE FROM live_events WHERE trace_id IN (${oldRunList});
      DELETE FROM annotations WHERE run_id IN (${oldRunList});
      DELETE FROM spans WHERE run_id IN (${oldRunList});
      DELETE FROM saved_run_cache WHERE id IN (${oldRunList});
      DELETE FROM runs WHERE id IN (${oldRunList});
    `);
  }
  await execSql(`DELETE FROM saved_events WHERE event_name = 'human_computer_use' AND saved_at < ${Math.floor(cutoffMs)};`);
  await pruneSearchRows(oldRunIds);

  let deletedScreenshots = 0;
  try {
    const files = await fs.readdir(recordedScreenshotDir);
    await Promise.all(files.map(async (file) => {
      try {
        const stat = await fs.stat(path.join(recordedScreenshotDir, file));
        if (!shotNames.has(file) && !(isHumanTraceScreenshotName(file) && stat.mtimeMs < cutoffMs)) return;
        await fs.unlink(path.join(recordedScreenshotDir, file));
        deletedScreenshots += 1;
      } catch {}
    }));
  } catch {}

  const [remaining] = await sqlite(`
    SELECT COUNT(*) AS spans
    FROM spans s JOIN runs r ON r.id = s.run_id
    WHERE r.event_name = 'human_computer_use'
  `);

  return {
    cutoffMs: Math.floor(cutoffMs),
    hours: safeHours,
    deletedRuns,
    deletedSpans: Number(oldSpanCount?.count ?? 0),
    deletedScreenshots,
    remainingSpans: Number(remaining?.spans ?? 0),
  };
}

function classify(a, row = {}) {
  const op = a['ai.operationId'] ?? '';
  if (op.includes('click')) return 'click';
  if (op.includes('scroll')) return 'scroll';
  if (op.includes('drag')) return 'drag';
  if (op.includes('typing') || op.includes('keyboard')) return 'typing';
  if (op.includes('focus')) return 'focus';
  if (op.includes('mouse')) return 'mouse';
  return row.span_type?.toLowerCase() ?? 'span';
}

function recentMinutesFromFlags(flags) {
  const raw = flags['since-minutes'] ?? flags['last-minutes'];
  if (raw == null || raw === '') return null;
  const minutes = Number(raw);
  return Number.isFinite(minutes) && minutes > 0 ? minutes : null;
}

function sinceCutoffMs(sinceMinutes) {
  return sinceMinutes ? Date.now() - sinceMinutes * 60 * 1000 : null;
}

function recentSpanWhere(alias, sinceMinutes) {
  const cutoff = sinceCutoffMs(sinceMinutes);
  return cutoff ? ` AND COALESCE(${alias}.start_time_ms, 0) >= ${Math.floor(cutoff)}` : '';
}

async function resolveRunId(value, sinceMinutes = null, { requireActions = false } = {}) {
  if (value && value !== 'latest') return value;
  return latestHumanTraceRunId({ sinceMinutes, requireActions });
}

async function search(q, { limit = 20, sinceMinutes = null } = {}) {
  await ensureSearchIndex();
  const rows = await sqlite(`
    SELECT s.id, s.run_id, s.parent_span_id, s.name, s.span_type, s.status,
           s.start_time_ms, s.end_time_ms, s.duration_ms, s.model, s.provider,
           s.input_tokens, s.output_tokens, s.attributes,
           r.name AS run_name, snippet(rewind_search, 4, '[', ']', ' ... ', 18) AS snippet
    FROM rewind_search
    JOIN spans s ON s.id = rewind_search.span_id
    JOIN runs r ON r.id = rewind_search.run_id
    WHERE rewind_search MATCH ${sqliteString(escapeFts(q))}
      ${recentSpanWhere('s', sinceMinutes)}
    ORDER BY s.start_time_ms DESC
    LIMIT ${Math.min(Math.max(limit, 1), 100)}
  `);
  return rows.map(hydrate);
}

async function plan(runId, { sinceMinutes = null } = {}) {
  const rows = await sqlite(`
    SELECT s.*, r.name AS run_name
    FROM spans s JOIN runs r ON r.id = s.run_id
    WHERE s.run_id = ?
      ${recentSpanWhere('s', sinceMinutes)}
    ORDER BY s.start_time_ms ASC
  `, [runId]);
  return rows.map(hydrate).filter((row) => row.replay.action);
}

async function span(spanId) {
  const [row] = await sqlite(`
    SELECT s.*, r.name AS run_name
    FROM spans s JOIN runs r ON r.id = s.run_id
    WHERE s.id = ?
    LIMIT 1
  `, [spanId]);
  if (!row) throw new Error(`span not found: ${spanId}`);
  return hydrate(row);
}

function hydrate(row) {
  const a = parseJson(row.attributes);
  return {
    runId: row.run_id,
    spanId: row.id,
    name: row.name,
    startTimeMs: row.start_time_ms,
    kind: classify(a, row),
    app: a['app.name'] ?? '',
    windowTitle: a['window.title'] ?? '',
    snippet: row.snippet,
    screenshot: screenshotFromAttributes(a),
    replay: replayAction(a),
    attributes: a,
  };
}

function screenshotFromAttributes(a) {
  const name = a['screenshot.name'] || (a['screenshot.path'] ? path.basename(a['screenshot.path']) : '');
  const rawPath = a['screenshot.path'] || (name ? path.join(recordedScreenshotDir, name) : '');
  if (!name && !rawPath) return null;
  const resolvedPath = rawPath.startsWith('/') ? rawPath : path.join(recordedScreenshotDir, rawPath);
  return {
    attached: a['screenshot.attached'] === 'true',
    capture: a['screenshot.capture'] || '',
    name,
    path: resolvedPath,
    exists: existsSync(resolvedPath),
  };
}

function replayAction(a) {
  const operation = a['ai.operationId'] ?? '';
  const action = a['replay.action'] || legacyReplayAction(operation);
  const target = parseJson(a['replay.target'], null);
  if (action === 'click') return { action, x: Number(a['click.last_x'] ?? a['replay.primary_x']), y: Number(a['click.last_y'] ?? a['replay.primary_y']), target };
  if (action === 'scroll') return { action, dx: Number(a['scroll.total_delta_x'] ?? 0), dy: Number(a['scroll.total_delta_y'] ?? 0), x: Number(a['scroll.last_x'] ?? a['replay.primary_x']), y: Number(a['scroll.last_y'] ?? a['replay.primary_y']), target };
  if (action === 'drag') return { action, from: [Number(a['drag.first_x'] ?? 0), Number(a['drag.first_y'] ?? 0)], to: [Number(a['drag.last_x'] ?? 0), Number(a['drag.last_y'] ?? 0)], durationMs: Number(a['drag.duration_ms'] ?? 250), target };
  if (action === 'type') return { action, text: a['keyboard.typed_text'] ?? '', keydownCount: Number(a['keyboard.keydown_count'] ?? 0) };
  if (action === 'key') return { action, keyCodes: a['keyboard.key_codes'] ?? '', modifiers: a['keyboard.modifiers'] ?? '' };
  if (action === 'move') return { action, x: Number(a['mouse.last_x'] ?? a['replay.primary_x']), y: Number(a['mouse.last_y'] ?? a['replay.primary_y']) };
  return { action };
}

function legacyReplayAction(operation) {
  if (operation.includes('click')) return 'click';
  if (operation.includes('scroll')) return 'scroll';
  if (operation.includes('drag')) return 'drag';
  if (operation.includes('typing') || operation.includes('keyboard')) return 'key';
  if (operation.includes('mouse')) return 'move';
  return '';
}

async function act(actionArgs) {
  if (!actionArgs.length) usage();
  const result = await swift(actionArgs);
  print(result);
}

async function runPlan(args) {
  const { positional, flags } = parseFlags(args);
  const sinceMinutes = recentMinutesFromFlags(flags);
  const runId = await resolveRunId(positional[0], sinceMinutes, { requireActions: true });
  if (!runId) usage();
  const actions = await plan(runId, { sinceMinutes });
  return executePlan(runId, actions, flags);
}

async function executePlan(runId, actions, flags = {}) {
  const limit = Number(flags.limit ?? actions.length);
  const delayMs = Number(flags['delay-ms'] ?? 120);
  const checkEvery = Number(flags['check-every'] ?? 0);
  const selected = actions.slice(0, Math.min(Math.max(limit || actions.length, 0), actions.length));
  const started = performance.now();
  const results = [];

  for (let index = 0; index < selected.length; index += 1) {
    const item = selected[index];
    const swiftArgs = swiftArgsForReplay(item.replay);
    const step = {
      index,
      spanId: item.spanId,
      name: item.name,
      action: item.replay.action,
      swiftArgs,
      skipped: !swiftArgs,
    };
    if (!flags['dry-run'] && swiftArgs) {
      const stepStart = performance.now();
      step.result = await swift(swiftArgs);
      step.durationMs = Math.round(performance.now() - stepStart);
      if (delayMs > 0) await swift(['wait', String(delayMs)]);
      if (checkEvery > 0 && (index + 1) % checkEvery === 0) {
        step.check = await swift(['inspect']);
      }
    }
    results.push(step);
  }

  return {
    ok: true,
    runId,
    dryRun: Boolean(flags['dry-run']),
    totalActions: actions.length,
    attemptedActions: selected.length,
    executableActions: results.filter((r) => r.swiftArgs).length,
    skippedActions: results.filter((r) => r.skipped).length,
    durationMs: Math.round(performance.now() - started),
    results,
  };
}

function parseFlags(values) {
  const positional = [];
  const flags = {};
  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    if (!value.startsWith('--')) {
      positional.push(value);
      continue;
    }
    const key = value.slice(2);
    if (key === 'dry-run') {
      flags[key] = true;
    } else {
      flags[key] = values[index + 1];
      index += 1;
    }
  }
  return { positional, flags };
}

function swiftArgsForReplay(replay) {
  if (!replay?.action) return null;
  if (replay.action === 'click' && finite(replay.x) && finite(replay.y)) return ['click', Math.round(replay.x), Math.round(replay.y)];
  if (replay.action === 'scroll' && finite(replay.dx) && finite(replay.dy)) {
    const args = ['scroll', Math.round(replay.dx), Math.round(replay.dy)];
    if (finite(replay.x) && finite(replay.y)) args.push(Math.round(replay.x), Math.round(replay.y));
    return args;
  }
  if (replay.action === 'drag' && Array.isArray(replay.from) && Array.isArray(replay.to)) {
    return ['drag', Math.round(replay.from[0]), Math.round(replay.from[1]), Math.round(replay.to[0]), Math.round(replay.to[1]), Math.max(80, Math.min(1500, Math.round(replay.durationMs || 250)))];
  }
  if (replay.action === 'type' && replay.text) return ['type', replay.text];
  if (replay.action === 'key' && replay.keyCodes) {
    const firstCode = String(replay.keyCodes).split(',')[0]?.split(':')[0];
    if (firstCode && Number.isFinite(Number(firstCode))) return ['key', firstCode, modifierList(replay.modifiers)];
  }
  if (replay.action === 'move' && finite(replay.x) && finite(replay.y)) return ['move', Math.round(replay.x), Math.round(replay.y)];
  return null;
}

function modifierList(value = '') {
  const modifiers = String(value).split(',').map((part) => part.split(':')[0]).filter((name) => ['cmd', 'shift', 'option', 'control'].includes(name));
  return modifiers.join(',');
}

function finite(value) {
  return Number.isFinite(Number(value));
}

async function swift(swiftArgs) {
  const { stdout } = await execFileAsync('swift', [swiftTool, ...swiftArgs.map(String)], { maxBuffer: 20 * 1024 * 1024 });
  return parseJson(stdout, { raw: stdout.trim() });
}

async function bench(args) {
  const nativeIndex = args.indexOf('--native-ms');
  const nativeMs = nativeIndex >= 0 ? Number(args[nativeIndex + 1]) : null;
  const runId = args.find((arg, index) => index !== nativeIndex && index !== nativeIndex + 1 && !arg.startsWith('--'));
  const started = performance.now();
  let actions = [];
  if (runId) actions = await plan(runId);
  const plannedAt = performance.now();
  const inspect = await swift(['inspect']);
  const inspectedAt = performance.now();
  const shot = await swift(['screenshot', path.join(replayScreenshotDir, `bench-${Date.now()}.png`)]);
  const finishedAt = performance.now();
  const toolkitMs = Math.round(finishedAt - started);
  const speedup = nativeMs ? nativeMs / toolkitMs : null;
  return {
    ok: true,
    runId: runId ?? null,
    actionCount: actions.length,
    timingsMs: {
      plan: Math.round(plannedAt - started),
      inspect: Math.round(inspectedAt - plannedAt),
      screenshot: Math.round(finishedAt - inspectedAt),
      total: toolkitMs,
    },
    nativeBaseline: {
      wallClockMs: nativeMs,
      speedup,
      passed: speedup == null ? null : speedup >= 2,
      note: 'Use the same task with native computer-use and compare wall-clock. Toolkit target is <= 50% of native time.',
      targetSpeedup: 2,
    },
    inspect,
    screenshot: shot,
  };
}

async function benchSuite(args) {
  const { positional, flags } = parseFlags(args);
  const nativeMs = flags['native-ms'] == null ? null : Number(flags['native-ms']);
  const limit = Math.max(1, Number(flags.limit ?? 25));
  const query = String(flags.query ?? 'human');
  const sinceMinutes = recentMinutesFromFlags(flags);
  const runId = await resolveRunId(positional[0], sinceMinutes, { requireActions: true });
  if (!runId) throw new Error('No human_computer_use run found to benchmark');

  const timings = {};
  const started = performance.now();

  let searchResults = [];
  const searchStart = performance.now();
  try {
    searchResults = await search(query, { limit: 10, sinceMinutes });
    timings.searchMs = Math.round(performance.now() - searchStart);
  } catch (err) {
    timings.searchMs = Math.round(performance.now() - searchStart);
    timings.searchError = err instanceof Error ? err.message : String(err);
  }

  const planStart = performance.now();
  const actions = await plan(runId, { sinceMinutes });
  timings.planMs = Math.round(performance.now() - planStart);

  const dryRunStart = performance.now();
  const dryRun = await executePlan(runId, actions, { 'dry-run': true, limit: String(limit), 'delay-ms': '0', 'check-every': '0' });
  timings.dryRunMs = Math.round(performance.now() - dryRunStart);
  timings.totalMs = Math.round(performance.now() - started);

  const actionCounts = {};
  for (const action of actions) actionCounts[action.replay.action] = (actionCounts[action.replay.action] ?? 0) + 1;
  const executableRatio = dryRun.attemptedActions > 0 ? dryRun.executableActions / dryRun.attemptedActions : 0;
  const speedup = nativeMs ? nativeMs / timings.totalMs : null;
  const report = {
    ok: true,
    createdAt: new Date().toISOString(),
    runId,
    query,
    sinceMinutes,
    limit,
    searchResultCount: searchResults.length,
    actionCount: actions.length,
    actionCounts,
    dryRun: {
      attemptedActions: dryRun.attemptedActions,
      executableActions: dryRun.executableActions,
      skippedActions: dryRun.skippedActions,
      executableRatio,
    },
    timings,
    nativeBaseline: {
      wallClockMs: nativeMs,
      speedup,
      targetSpeedup: 2,
      passed: speedup == null ? null : speedup >= 2,
    },
    bottlenecks: benchmarkBottlenecks({ timings, dryRun, actions, nativeMs, speedup }),
  };

  const outputPath = flags.output ? path.resolve(String(flags.output)) : path.join(benchmarkDir, 'computer-use-replay-benchmarks.jsonl');
  await fs.mkdir(path.dirname(outputPath), { recursive: true });
  await fs.appendFile(outputPath, JSON.stringify(report) + '\n', 'utf8');
  report.outputPath = outputPath;
  return report;
}

async function latestHumanTraceRunId({ sinceMinutes = null, requireActions = false } = {}) {
  const [row] = await sqlite(`
    SELECT id
    FROM runs
    WHERE event_name = 'human_computer_use'
      AND COALESCE(metadata, '') NOT LIKE '%computer_use_replay_server%'
      ${sinceCutoffMs(sinceMinutes) ? `AND EXISTS (
        SELECT 1 FROM spans s
        WHERE s.run_id = runs.id
          ${recentSpanWhere('s', sinceMinutes)}
      )` : ''}
      ${requireActions ? `AND EXISTS (
        SELECT 1 FROM spans replay_spans
        WHERE replay_spans.run_id = runs.id
          AND replay_spans.attributes LIKE '%"replay.action"%'
      )` : ''}
    ORDER BY last_updated_at DESC
    LIMIT 1
  `);
  return row?.id ?? '';
}

function benchmarkBottlenecks({ timings, dryRun, actions, nativeMs, speedup }) {
  const bottlenecks = [];
  if (timings.searchError) bottlenecks.push(`Search failed during benchmark: ${timings.searchError}`);
  if (nativeMs && speedup < 2) bottlenecks.push('Toolkit did not reach 2x native baseline; inspect the largest timing component first.');
  if (timings.searchMs > timings.planMs && timings.searchMs > timings.dryRunMs) bottlenecks.push('Search/index refresh dominates this benchmark; cache or incrementally update FTS.');
  if (timings.planMs > timings.searchMs && timings.planMs > timings.dryRunMs) bottlenecks.push('Plan extraction dominates this benchmark; reduce per-span hydration or precompute replay actions.');
  if (timings.dryRunMs > timings.searchMs && timings.dryRunMs > timings.planMs) bottlenecks.push('Dry-run plan execution dominates this benchmark; reduce per-step work before enabling real actions.');
  if (dryRun.skippedActions > 0) bottlenecks.push(`${dryRun.skippedActions} planned actions were not executable; add recorder fields or action translation support.`);
  const keyActions = actions.filter((item) => item.replay.action === 'key');
  if (keyActions.length > 0) bottlenecks.push(`${keyActions.length} keyboard bursts only have key histograms; enable typed-text capture for faithful text replay when safe.`);
  if (!bottlenecks.length) bottlenecks.push('No obvious benchmark bottleneck from dry-run metrics.');
  return bottlenecks;
}

function print(value) {
  console.log(JSON.stringify(value, null, 2));
}
