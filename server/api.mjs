import cors from 'cors';
import express from 'express';
import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const app = express();
const port = Number(process.env.REWIND_API_PORT ?? 4317);
const dbPath = process.env.RAINDROP_WORKSHOP_DB ?? path.join(os.homedir(), '.raindrop', 'raindrop_workshop.db');
const screenshotDir = process.env.HUMAN_TRACE_SCREENSHOT_DIR ?? path.join(os.homedir(), '.raindrop', 'human-trace-screenshots');
const bridgeDir = path.join(os.homedir(), '.raindrop');
const recorderControlPath = path.join(bridgeDir, 'human-trace-control.json');
const recorderStatusPath = path.join(bridgeDir, 'human-trace-status.json');

app.use(cors({ origin: true }));
app.use(express.json({ limit: '1mb' }));

async function sqlite(args, opts = {}) {
  const { stdout } = await execFileAsync('sqlite3', args, { maxBuffer: opts.maxBuffer ?? 80 * 1024 * 1024 });
  return stdout;
}

async function sql(query, params = []) {
  if (!existsSync(dbPath)) return [];
  const stdout = await sqlite(['-cmd', '.timeout 5000', '-json', dbPath, bindSql(query, params)]);
  const trimmed = stdout.trim();
  return trimmed ? JSON.parse(trimmed) : [];
}

async function execSql(script) {
  if (!existsSync(dbPath)) return;
  await sqlite(['-cmd', '.timeout 5000', dbPath, script], { maxBuffer: 80 * 1024 * 1024 });
}

function parseJson(value, fallback = {}) {
  if (!value) return fallback;
  try { return JSON.parse(value); } catch { return fallback; }
}

function attrs(span) { return parseJson(span.attributes, {}); }
function isRewindViewerSpanAttributes(a) {
  const windowTitle = String(a['window.title'] ?? '').toLowerCase();
  const appName = String(a['app.name'] ?? '').toLowerCase();
  return windowTitle.includes('mochi rewind')
    || windowTitle.includes('127.0.0.1:5173')
    || windowTitle.includes('localhost:5173')
    || (appName === 'dia' && windowTitle === 'rewind');
}
function screenshotUrlFromAttributes(a) {
  if (isRewindViewerSpanAttributes(a)) return null;
  if (a['screenshot.attached'] === 'true' && a['screenshot.capture'] !== 'focused_window') return null;
  const name = a['screenshot.name'] || (a['screenshot.path'] ? path.basename(a['screenshot.path']) : '');
  return name ? `/screenshots/${encodeURIComponent(name)}` : null;
}
function classifySpan(span) {
  const a = attrs(span);
  const op = a['ai.operationId'] ?? '';
  if (op.includes('click')) return 'click';
  if (op.includes('scroll')) return 'scroll';
  if (op.includes('drag')) return 'drag';
  if (op.includes('typing') || op.includes('keyboard')) return 'typing';
  if (op.includes('focus')) return 'focus';
  if (op.includes('mouse')) return 'mouse';
  return span.span_type?.toLowerCase() ?? 'span';
}
function hydrateSpan(span) {
  const a = attrs(span);
  return {
    ...span,
    attributes: a,
    kind: classifySpan(span),
    screenshotUrl: screenshotUrlFromAttributes(a),
    uiSummary: a['ui.last.title'] || a['ui.last.value'] || a['ui.last.role'] || a['ui.first.title'] || a['ui.first.value'] || a['ui.first.role'] || '',
  };
}
function replayActionFromAttributes(a) {
  const action = a['replay.action'] || legacyReplayAction(a['ai.operationId'] || '');
  const target = parseJson(a['replay.target'], null);
  const base = {
    action,
    app: a['app.name'] || '',
    bundle: a['app.bundle'] || '',
    windowTitle: a['window.title'] || '',
    target,
    screenshot: screenshotUrlFromAttributes(a),
  };
  if (action === 'click') {
    return { ...base, x: Number(a['click.last_x'] ?? a['replay.primary_x']), y: Number(a['click.last_y'] ?? a['replay.primary_y']), buttons: a['click.buttons'] || 'left:1' };
  }
  if (action === 'scroll') {
    return { ...base, x: Number(a['scroll.last_x'] ?? a['replay.primary_x']), y: Number(a['scroll.last_y'] ?? a['replay.primary_y']), dx: Number(a['scroll.total_delta_x'] ?? 0), dy: Number(a['scroll.total_delta_y'] ?? 0) };
  }
  if (action === 'drag') {
    return { ...base, from: [Number(a['drag.first_x'] ?? 0), Number(a['drag.first_y'] ?? 0)], to: [Number(a['drag.last_x'] ?? 0), Number(a['drag.last_y'] ?? 0)], durationMs: Number(a['drag.duration_ms'] ?? 250), button: a['drag.button'] || 'left' };
  }
  if (action === 'type') return { ...base, text: a['keyboard.typed_text'] || '', keydownCount: Number(a['keyboard.keydown_count'] ?? 0) };
  if (action === 'key') return { ...base, keyCodes: a['keyboard.key_codes'] || '', modifiers: a['keyboard.modifiers'] || '' };
  if (action === 'move') return { ...base, x: Number(a['mouse.last_x'] ?? a['replay.primary_x']), y: Number(a['mouse.last_y'] ?? a['replay.primary_y']) };
  return base;
}
function legacyReplayAction(operation) {
  if (operation.includes('click')) return 'click';
  if (operation.includes('scroll')) return 'scroll';
  if (operation.includes('drag')) return 'drag';
  if (operation.includes('typing') || operation.includes('keyboard')) return 'key';
  if (operation.includes('mouse')) return 'move';
  return '';
}
function hydrateReplaySpan(span) {
  const hydrated = hydrateSpan(span);
  hydrated.replay = replayActionFromAttributes(hydrated.attributes);
  return hydrated;
}
function searchTextFor(row) {
  const a = parseJson(row.attributes, {});
  const text = [
    row.run_name, row.event_name, row.span_name, row.span_type, row.input_payload, row.output_payload,
    a['app.name'], a['app.bundle'], a['window.title'], a['keyboard.typed_text'],
    a['replay.action'], a['replay.kind'], a['replay.target'],
    a['ui.first.role'], a['ui.first.title'], a['ui.first.value'], a['ui.first.description'], a['ui.first.identifier'], a['ui.first.ancestry'],
    a['ui.last.role'], a['ui.last.title'], a['ui.last.value'], a['ui.last.description'], a['ui.last.identifier'], a['ui.last.ancestry'],
    a['ai.toolCall.name'], a['ai.toolCall.args'], a['ai.toolCall.result'],
    a['screenshot.name'], a['screenshot.path'], row.run_metadata,
  ].filter(Boolean).join('\n');
  return text.length > 4000 ? text.slice(0, 4000) : text;
}
function escapeFts(query) {
  return query.trim().split(/\s+/).filter(Boolean).map((term) => `"${term.replaceAll('"', '""')}"`).join(' AND ');
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
function recentMinutesFromRequest(req) {
  const raw = req.query.sinceMinutes ?? req.query.since_minutes ?? req.query.lastMinutes ?? req.query.last_minutes;
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
function isHumanTraceScreenshotName(file) {
  return /^(click|typing|drag)_burst-\d+\.png$/.test(file);
}

async function readRecorderStatus() {
  try {
    const status = parseJson(await fs.readFile(recorderStatusPath, 'utf8'), null);
    if (!status) throw new Error('invalid status');
    const updatedAt = Number(status.updatedAt ?? 0);
    return { available: Date.now() - updatedAt < 5000, ...status };
  } catch {
    return { available: false, recording: false, screenshotsEnabled: false, typedTextEnabled: false, updatedAt: null };
  }
}

async function writeRecorderCommand(command) {
  await fs.mkdir(bridgeDir, { recursive: true });
  const body = { command, nonce: `${Date.now()}-${Math.random().toString(16).slice(2)}`, createdAt: Date.now() };
  await fs.writeFile(recorderControlPath, JSON.stringify(body), 'utf8');
  return body;
}

async function waitForRecorderState(recording, timeoutMs = 3500) {
  const deadline = Date.now() + timeoutMs;
  let status = await readRecorderStatus();
  while ((!status.available || Boolean(status.recording) !== recording) && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 180));
    status = await readRecorderStatus();
  }
  return status;
}

async function screenshotNamesForPrune(cutoffMs) {
  const rows = await sql(`
    SELECT s.attributes
    FROM spans s JOIN runs r ON r.id = s.run_id
    WHERE r.event_name = 'human_computer_use'
      AND COALESCE(s.start_time_ms, r.started_at) < ${cutoffMs}
      AND s.attributes LIKE '%screenshot%'
  `);
  return new Set(rows.map((row) => {
    const a = parseJson(row.attributes, {});
    return a['screenshot.name'] || (a['screenshot.path'] ? path.basename(a['screenshot.path']) : '');
  }).filter(Boolean));
}

async function deleteSearchRows(runIds) {
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
    ${runIds.length ? `DELETE FROM rewind_search WHERE run_id IN (${runIds.map(sqliteString).join(',')});
    DELETE FROM rewind_search_indexed_spans WHERE run_id IN (${runIds.map(sqliteString).join(',')});` : ''}
    DELETE FROM rewind_search WHERE span_id NOT IN (SELECT id FROM spans);
    DELETE FROM rewind_search_indexed_spans WHERE span_id NOT IN (SELECT id FROM spans);
  `);
}

async function pruneHumanTraceData({ hours = 2 } = {}) {
  const safeHours = Math.max(0.1, Math.min(Number(hours) || 2, 168));
  const cutoffMs = Date.now() - safeHours * 60 * 60 * 1000;
  const oldRunRows = await sql(`
    SELECT r.id
    FROM runs r
    WHERE r.event_name = 'human_computer_use'
      AND (
        COALESCE(r.last_updated_at, r.started_at) < ${cutoffMs}
        OR NOT EXISTS (
          SELECT 1 FROM spans s
          WHERE s.run_id = r.id AND COALESCE(s.start_time_ms, r.started_at) >= ${cutoffMs}
        )
      )
  `);
  const oldRunIds = oldRunRows.map((row) => row.id).filter(Boolean);
  const oldRunList = oldRunIds.map(sqliteString).join(',');
  const shotNames = await screenshotNamesForPrune(cutoffMs);

  let deletedSpans = 0;
  let deletedRuns = 0;
  const [oldSpanCount] = await sql(`
    SELECT COUNT(*) AS count
    FROM spans s JOIN runs r ON r.id = s.run_id
    WHERE r.event_name = 'human_computer_use'
      AND COALESCE(s.start_time_ms, r.started_at) < ${cutoffMs}
  `);
  deletedSpans = Number(oldSpanCount?.count ?? 0);
  await execSql(`
    DELETE FROM spans
    WHERE id IN (
      SELECT s.id
      FROM spans s JOIN runs r ON r.id = s.run_id
      WHERE r.event_name = 'human_computer_use'
        AND COALESCE(s.start_time_ms, r.started_at) < ${cutoffMs}
    );
  `);

  if (oldRunIds.length) {
    const [runCount] = await sql(`SELECT COUNT(*) AS count FROM runs WHERE id IN (${oldRunList})`);
    deletedRuns = Number(runCount?.count ?? 0);
    await execSql(`
      DELETE FROM live_events WHERE trace_id IN (${oldRunList});
      DELETE FROM annotations WHERE run_id IN (${oldRunList});
      DELETE FROM spans WHERE run_id IN (${oldRunList});
      DELETE FROM saved_run_cache WHERE id IN (${oldRunList});
      DELETE FROM runs WHERE id IN (${oldRunList});
    `);
  }
  await execSql(`DELETE FROM saved_events WHERE event_name = 'human_computer_use' AND saved_at < ${cutoffMs};`);
  await deleteSearchRows(oldRunIds);

  let deletedScreenshots = 0;
  try {
    const files = await fs.readdir(screenshotDir);
    await Promise.all(files.map(async (file) => {
      try {
        const stat = await fs.stat(path.join(screenshotDir, file));
        if (!shotNames.has(file) && !(isHumanTraceScreenshotName(file) && stat.mtimeMs < cutoffMs)) return;
        await fs.unlink(path.join(screenshotDir, file));
        deletedScreenshots += 1;
      } catch {}
    }));
  } catch {}

  return { cutoffMs, hours: safeHours, deletedRuns, deletedSpans, deletedScreenshots };
}

async function rebuildSearchIndex() {
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
  const rows = await sql(`
    SELECT r.id AS run_id, s.id AS span_id, r.event_name, r.name AS run_name,
           substr(COALESCE(r.metadata, ''), 1, 1000) AS run_metadata,
           s.name AS span_name, s.span_type,
           substr(COALESCE(s.input_payload, ''), 1, 1000) AS input_payload,
           substr(COALESCE(s.output_payload, ''), 1, 1000) AS output_payload,
           substr(COALESCE(s.attributes, ''), 1, 5000) AS attributes
    FROM spans s JOIN runs r ON r.id = s.run_id
    WHERE r.event_name = 'human_computer_use'
    ORDER BY s.start_time_ms ASC
  `);
  const tuples = rows.map((row) => {
    const values = [row.run_id, row.span_id, classifySpan({ ...row, name: row.span_name }), row.span_name ?? '', searchTextFor(row)];
    const quoted = values.map((v) => `'${String(v ?? '').replaceAll("'", "''")}'`);
    return `(${quoted.join(',')})`;
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
  const rows = await sql(`
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
    const values = [row.run_id, row.span_id, classifySpan({ ...row, name: row.span_name }), row.span_name ?? '', searchTextFor(row)];
    const quoted = values.map((v) => `'${String(v ?? '').replaceAll("'", "''")}'`);
    return `(${quoted.join(',')})`;
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

app.get('/health', (_req, res) => res.json({ ok: true, dbPath, screenshotDir }));

app.get('/api/recorder/status', async (_req, res) => {
  res.json(await readRecorderStatus());
});

app.post('/api/recorder/:command', async (req, res, next) => {
  try {
    const command = req.params.command === 'stop' ? 'stop' : req.params.command === 'start' ? 'start' : null;
    if (!command) return res.status(400).json({ error: 'command must be start or stop' });
    await writeRecorderCommand(command);
    const status = await waitForRecorderState(command === 'start');
    res.json({ ok: status.available && Boolean(status.recording) === (command === 'start'), status });
  } catch (err) { next(err); }
});

app.post('/api/prune', async (req, res, next) => {
  try {
    const hours = Number(req.query.hours ?? req.body?.hours ?? 2);
    res.json({ ok: true, ...(await pruneHumanTraceData({ hours })) });
  } catch (err) { next(err); }
});

app.post('/api/index/rebuild', async (_req, res, next) => {
  try { res.json({ ok: true, indexed: await rebuildSearchIndex() }); } catch (err) { next(err); }
});

app.get('/api/runs', async (req, res, next) => {
  try {
    const sinceMinutes = recentMinutesFromRequest(req);
    const rows = await sql(`
      SELECT r.id, r.event_id, r.name, r.event_name, r.user_id, r.convo_id,
             r.started_at, r.last_updated_at, r.metadata,
             h.span_count, h.payload_total_chars
      FROM runs r LEFT JOIN runs_with_hints h ON h.id = r.id
      WHERE r.event_name = 'human_computer_use'
        ${sinceCutoffMs(sinceMinutes) ? `AND EXISTS (
          SELECT 1 FROM spans s
          WHERE s.run_id = r.id
            ${recentSpanWhere('s', sinceMinutes)}
        )` : ''}
      ORDER BY r.last_updated_at DESC LIMIT 200
    `);
    res.json(rows.map((run) => ({ ...run, metadata: parseJson(run.metadata, {}) })));
  } catch (err) { next(err); }
});

app.get('/api/timeline', async (req, res, next) => {
  try {
    const requestedLimit = Number(req.query.limit ?? 1200);
    const limit = Math.min(Math.max(Number.isFinite(requestedLimit) ? requestedLimit : 1200, 1), 5000);
    const sinceMinutes = recentMinutesFromRequest(req);
    const spans = await sql(`
      SELECT * FROM (
        SELECT s.*, r.event_name, r.name AS run_name, r.last_updated_at AS run_last_updated
        FROM spans s JOIN runs r ON r.id = s.run_id
        WHERE r.event_name = 'human_computer_use'
          ${recentSpanWhere('s', sinceMinutes)}
        ORDER BY s.start_time_ms DESC
        LIMIT ${limit}
      )
      ORDER BY start_time_ms ASC
    `);
    res.json(spans.map(hydrateSpan));
  } catch (err) { next(err); }
});

app.get('/api/runs/:id', async (req, res, next) => {
  try {
    const [run] = await sql(`
      SELECT r.id, r.event_id, r.name, r.event_name, r.user_id, r.convo_id,
             r.started_at, r.last_updated_at, r.metadata,
             h.span_count, h.payload_total_chars
      FROM runs r LEFT JOIN runs_with_hints h ON h.id = r.id
      WHERE r.id = ? LIMIT 1
    `, [req.params.id]);
    if (!run) return res.status(404).json({ error: 'run not found' });
    const spans = await sql(`SELECT * FROM spans WHERE run_id = ? ORDER BY start_time_ms ASC`, [req.params.id]);
    res.json({ ...run, metadata: parseJson(run.metadata, {}), spans: spans.map(hydrateSpan) });
  } catch (err) { next(err); }
});

app.get('/api/search', async (req, res, next) => {
  try {
    const q = String(req.query.q ?? '').trim();
    const sinceMinutes = recentMinutesFromRequest(req);
    if (!q) return res.json([]);
    await ensureSearchIndex();
    const fts = escapeFts(q).replaceAll("'", "''");
    const rows = await sql(`
      SELECT rewind_search.run_id, rewind_search.span_id, rewind_search.kind, rewind_search.title,
             snippet(rewind_search, 4, '<mark>', '</mark>', ' … ', 16) AS snippet
      FROM rewind_search
      JOIN spans s ON s.id = rewind_search.span_id
      WHERE rewind_search MATCH '${fts}'
        ${recentSpanWhere('s', sinceMinutes)}
      LIMIT 80
    `);
    res.json(rows);
  } catch (err) { next(err); }
});

app.get('/api/replay/search', async (req, res, next) => {
  try {
    const q = String(req.query.q ?? '').trim();
    const limit = Math.min(Math.max(Number(req.query.limit ?? 20) || 20, 1), 100);
    const sinceMinutes = recentMinutesFromRequest(req);
    if (!q) return res.json([]);
    await ensureSearchIndex();
    const fts = escapeFts(q).replaceAll("'", "''");
    const rows = await sql(`
      SELECT s.id, s.run_id, s.parent_span_id, s.name, s.span_type, s.status,
             s.start_time_ms, s.end_time_ms, s.duration_ms, s.model, s.provider,
             s.input_tokens, s.output_tokens, s.attributes,
             r.event_name, r.name AS run_name,
             snippet(rewind_search, 4, '<mark>', '</mark>', ' … ', 20) AS search_snippet
      FROM rewind_search
      JOIN spans s ON s.id = rewind_search.span_id
      JOIN runs r ON r.id = rewind_search.run_id
      WHERE rewind_search MATCH '${fts}'
        ${recentSpanWhere('s', sinceMinutes)}
      ORDER BY s.start_time_ms DESC
      LIMIT ${limit}
    `);
    res.json(rows.map(hydrateReplaySpan));
  } catch (err) { next(err); }
});

app.get('/api/replay/run/:id/plan', async (req, res, next) => {
  try {
    const sinceMinutes = recentMinutesFromRequest(req);
    const rows = await sql(`
      SELECT s.*, r.event_name, r.name AS run_name
      FROM spans s JOIN runs r ON r.id = s.run_id
      WHERE s.run_id = ?
        ${recentSpanWhere('s', sinceMinutes)}
      ORDER BY COALESCE(CAST(json_extract(s.attributes, '$."trace.sequence"') AS INTEGER), s.start_time_ms) ASC
    `, [req.params.id]);
    const spans = rows.map(hydrateReplaySpan).filter((span) => span.replay?.action);
    res.json({
      runId: req.params.id,
      actions: spans.map((span) => ({
        spanId: span.id,
        name: span.name,
        startTimeMs: span.start_time_ms,
        sequence: Number(span.attributes['trace.sequence'] ?? 0),
        ...span.replay,
      })),
    });
  } catch (err) { next(err); }
});

app.get('/api/replay/span/:id', async (req, res, next) => {
  try {
    const [row] = await sql(`
      SELECT s.*, r.event_name, r.name AS run_name
      FROM spans s JOIN runs r ON r.id = s.run_id
      WHERE s.id = ?
      LIMIT 1
    `, [req.params.id]);
    if (!row) return res.status(404).json({ error: 'span not found' });
    res.json(hydrateReplaySpan(row));
  } catch (err) { next(err); }
});

app.use('/screenshots', express.static(screenshotDir, { setHeaders(res) { res.setHeader('Access-Control-Allow-Origin', '*'); } }));
app.use((err, _req, res, _next) => { console.error(err); res.status(500).json({ error: err.message }); });

app.listen(port, '127.0.0.1', () => {
  console.log(`Human Rewind API http://127.0.0.1:${port}`);
  console.log(`DB ${dbPath}`);
  console.log(`Screenshots ${screenshotDir}`);
  pruneHumanTraceData({ hours: Number(process.env.REWIND_PRUNE_HOURS ?? 2) })
    .then((result) => console.log(`Pruned human traces older than ${result.hours}h: ${result.deletedRuns} runs, ${result.deletedSpans} spans, ${result.deletedScreenshots} screenshots`))
    .catch((err) => console.error('Initial prune failed', err));
});

setInterval(() => {
  pruneHumanTraceData({ hours: Number(process.env.REWIND_PRUNE_HOURS ?? 2) })
    .catch((err) => console.error('Scheduled prune failed', err));
}, 10 * 60 * 1000).unref();
