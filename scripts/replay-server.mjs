#!/usr/bin/env node
import express from 'express';
import { execFile } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const app = express();
const PORT = 61020;
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const command = 'npm run replay:server';
const eventName = 'human_computer_use';
const endpoint = (process.env.RAINDROP_LOCAL_DEBUGGER ?? 'http://localhost:5899/v1/').replace(/\/+$/, '') + '/';

app.use(express.json({ limit: '2mb' }));

const input = {
  execute: 'boolean',
  limit: 'number',
  delayMs: 'number',
  checkEvery: 'number',
};

const prefillFromTrace = {
  execute: 'properties.replay.execute',
  limit: 'properties.replay.limit',
  delayMs: 'properties.replay.delayMs',
  checkEvery: 'properties.replay.checkEvery',
};

app.get('/health', (_req, res) => {
  res.json({
    ok: true,
    eventName,
    port: PORT,
    cwd: root,
    command,
    input,
    prefillFromTrace,
    models: [],
  });
});

app.post('/replay', async (req, res) => {
  const request = req.body ?? {};
  const replayRunId = String(request.replayRunId || randomHex(8));
  const sourceRunId = String(request.sourceRunId || request.context?.sourceRunId || request.context?.runId || '');
  const context = request.context ?? {};
  const execute = context.execute === true || context.execute === 'true';
  const limit = numberOr(context.limit, execute ? 50 : 25);
  const delayMs = numberOr(context.delayMs, 120);
  const checkEvery = numberOr(context.checkEvery, execute ? 5 : 0);
  const started = Date.now();

  if (!sourceRunId) {
    const message = 'Replay request is missing sourceRunId; select a Workshop run before replaying.';
    await emitReplayTrace({ replayRunId, sourceRunId, status: 'error', message, started });
    return res.status(400).json({ status: 'error', message });
  }

  try {
    const args = ['scripts/replay.mjs', 'run-plan', sourceRunId, '--limit', String(limit), '--delay-ms', String(delayMs), '--check-every', String(checkEvery)];
    if (!execute) args.push('--dry-run');
    const { stdout, stderr } = await execFileAsync('node', args, {
      cwd: root,
      env: { ...process.env, RAINDROP_LOCAL_DEBUGGER: endpoint },
      maxBuffer: 80 * 1024 * 1024,
    });
    const result = parseJson(stdout, { raw: stdout.trim() });
    await emitReplayTrace({ replayRunId, sourceRunId, status: 'done', result, stderr, started, execute });
    res.json({ replayId: replayRunId, status: 'done', sourceRunId, execute, result });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await emitReplayTrace({ replayRunId, sourceRunId, status: 'error', message, stack: err?.stack, started, execute });
    res.status(500).json({ replayId: replayRunId, status: 'error', message, stack: err?.stack });
  }
});

app.listen(PORT, '127.0.0.1', () => {
  console.log(`Computer-use replay server http://127.0.0.1:${PORT}`);
});

function numberOr(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function parseJson(value, fallback = {}) {
  try { return JSON.parse(value); } catch { return fallback; }
}

async function emitReplayTrace({ replayRunId, sourceRunId, status, result, stderr, message, stack, started, execute = false }) {
  const traceId = randomHex(16);
  const rootSpanId = randomHex(8);
  const end = Date.now();
  const inputPayload = {
    sourceRunId,
    execute,
    safety: execute ? 'macos_actions_enabled_by_context' : 'dry_run_no_macos_actions',
  };
  const outputPayload = status === 'done' ? summarizeResult(result) : { status, message };
  await postJSON('events/track_partial', {
    event_id: replayRunId,
    user_id: os.userInfo().username,
    event: eventName,
    timestamp: new Date(started).toISOString(),
    ai_data: {
      input: `Replay computer-use trace ${sourceRunId}`,
      output: status === 'done' ? `Replay ${execute ? 'executed' : 'planned'} ${outputPayload.attemptedActions ?? 0} actions` : `Replay failed: ${message}`,
      model: 'computer-use-replay/local',
      convo_id: replayRunId,
    },
    properties: {
      source: 'computer_use_replay_server',
      sourceRunId,
      replayRunId,
      'replay.execute': execute,
      'replay.status': status,
    },
    is_pending: status !== 'done' && status !== 'error',
  });

  await postJSON('traces', {
    resourceSpans: [{
      resource: { attributes: [attr('service.name', 'computer-use-replay-server')] },
      scopeSpans: [{
        scope: { name: 'computer-use-replay-server', version: '0.1.0' },
        spans: [{
          traceId,
          spanId: rootSpanId,
          name: execute ? 'execute computer-use replay plan' : 'dry-run computer-use replay plan',
          startTimeUnixNano: String(started * 1_000_000),
          endTimeUnixNano: String(end * 1_000_000),
          status: { code: status === 'done' ? 1 : 2, message: message ?? '' },
          attributes: [
            attr('ai.telemetry.metadata.raindrop.eventId', replayRunId),
            attr('ai.operationId', 'computer_use.replay'),
            attr('sourceRunId', sourceRunId),
            attr('replayRunId', replayRunId),
            attr('replay.execute', execute ? 'true' : 'false'),
            attr('replay.status', status),
            attr('replay.duration_ms', end - started),
            attr('replay.total_actions', outputPayload.totalActions ?? 0),
            attr('replay.attempted_actions', outputPayload.attemptedActions ?? 0),
            attr('replay.executable_actions', outputPayload.executableActions ?? 0),
            attr('replay.skipped_actions', outputPayload.skippedActions ?? 0),
            attr('ai.toolCall.name', 'computer_use.run_plan'),
            attr('ai.toolCall.args', JSON.stringify(inputPayload)),
            attr('ai.toolCall.result', JSON.stringify({ ...outputPayload, stderr: stderr?.slice(0, 1000), stack: stack?.slice(0, 1000) })),
          ],
          input: JSON.stringify(inputPayload),
          output: JSON.stringify(outputPayload),
        }],
      }],
    }],
  });
}

function summarizeResult(result) {
  return {
    status: result?.ok ? 'done' : 'unknown',
    dryRun: Boolean(result?.dryRun),
    totalActions: Number(result?.totalActions ?? 0),
    attemptedActions: Number(result?.attemptedActions ?? 0),
    executableActions: Number(result?.executableActions ?? 0),
    skippedActions: Number(result?.skippedActions ?? 0),
    durationMs: Number(result?.durationMs ?? 0),
  };
}

async function postJSON(route, body) {
  const response = await fetch(endpoint + route, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`Workshop ingest failed ${response.status}: ${await response.text()}`);
}

function attr(key, value) {
  if (typeof value === 'number' && Number.isFinite(value)) return { key, value: { intValue: String(Math.trunc(value)) } };
  return { key, value: { stringValue: String(value ?? '') } };
}

function randomHex(bytes) {
  return Array.from(crypto.getRandomValues(new Uint8Array(bytes)), (b) => b.toString(16).padStart(2, '0')).join('');
}
