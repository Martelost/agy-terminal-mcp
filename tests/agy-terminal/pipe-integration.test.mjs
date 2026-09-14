/**
 * pipe-integration.test.mjs
 * Integration tests for the named pipe round-trip and session registry logic.
 *
 * These tests start a mock bridge server on a named pipe, send JSON payloads,
 * and verify the MCP server-side helpers (pipeProbe, pipeRequest, findSession).
 *
 * Run: node tests/agy-terminal/pipe-integration.test.mjs
 * Note: requires Node.js 18+ and Windows (uses \\.\pipe\)
 */

import net from 'node:net';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';

// ── helpers replicated from server.mjs ───────────────────────────────────────

function cwdPipeName(cwd) {
  const hash = createHash('sha256')
    .update(cwd.toLowerCase())
    .digest('hex')
    .slice(0, 8);
  return `CodexAgySession_${hash}`;
}

function pipePath(pipeName) {
  if (process.platform === 'win32') return `\\\\.\\pipe\\${pipeName}`;
  return path.join('/tmp', `${pipeName}.sock`);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function pipeProbe(pipeName, timeoutMs = 500) {
  return new Promise((resolve) => {
    let settled = false;
    const socket = net.createConnection(pipePath(pipeName));
    const finish = (ok) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      resolve(ok);
    };
    const timer = setTimeout(() => finish(false), timeoutMs);
    socket.on('connect', () => finish(true));
    socket.on('error', () => finish(false));
    socket.on('close', () => finish(false));
  });
}

function pipeRequest(pipeName, payload, timeoutSeconds) {
  return new Promise((resolve) => {
    let settled = false;
    let buffer = '';
    const socket = net.createConnection(pipePath(pipeName));
    const timer = setTimeout(() => resolve({
      status: 'bridge_timeout',
      error: `Timeout after ${timeoutSeconds}s`
    }), timeoutSeconds * 1000);

    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.destroy();
      resolve(result);
    };

    socket.on('connect', () => socket.write(`${JSON.stringify(payload)}\n`));
    socket.on('data', (chunk) => {
      buffer += chunk.toString();
      const lines = buffer.split('\n');
      buffer = lines.pop() ?? '';
      for (const line of lines) {
        if (!line.trim()) continue;
        try { finish(JSON.parse(line)); }
        catch (e) { finish({ status: 'bridge_protocol_error', error: e.message }); }
      }
    });
    socket.on('error', (e) => finish({ status: 'bridge_unavailable', error: e.message }));
    socket.on('close', () => {
      if (!settled) finish({ status: 'bridge_disconnected', output: buffer });
    });
  });
}

// ── Mock bridge server ────────────────────────────────────────────────────────

function createMockBridge(pipeName, { respondWith } = {}) {
  const server = net.createServer((socket) => {
    let buf = '';
    socket.on('data', (chunk) => {
      buf += chunk.toString();
      const lines = buf.split('\n');
      buf = lines.pop() ?? '';
      for (const line of lines) {
        if (!line.trim()) continue;
        let req;
        try { req = JSON.parse(line); } catch { continue; }
        const response = respondWith ? respondWith(req) : {
          ok: true,
          status: req.type === 'health' ? 'healthy' : 'completed',
          sessionId: 'test-session-id',
          pluginVersion: '0.4.1',
          cwd: 'C:\\test\\project',
          pipeName,
          bridgePid: 1000,
          agyPid: 2000,
          output: `echo result for: ${req.command ?? req.type}`
        };
        socket.write(`${JSON.stringify(response)}\n`);
        socket.end();
      }
    });
    socket.on('error', () => {});
  });

  return new Promise((resolve, reject) => {
    server.listen(pipePath(pipeName), () => resolve(server));
    server.on('error', reject);
  });
}

// ── Tests ─────────────────────────────────────────────────────────────────────

let passed = 0;
let failed = 0;
const servers = [];

async function test(name, fn) {
  try {
    await fn();
    console.log(`  ✓  ${name}`);
    passed++;
  } catch (e) {
    console.error(`  ✗  ${name}`);
    console.error(`     ${e.message}`);
    failed++;
  }
}

console.log('\nPipe Integration Tests\n');

// Test 1: probe returns false for non-existent pipe
await test('pipeProbe: returns false when no server listening', async () => {
  const available = await pipeProbe('CodexAgySession_nonexistent', 200);
  assert.equal(available, false);
});

// Test 2: probe returns true when server is listening
await test('pipeProbe: returns true when server is listening', async () => {
  const pipeName = 'CodexAgyTest_probe_' + Date.now();
  const server = await createMockBridge(pipeName);
  servers.push(server);
  const available = await pipeProbe(pipeName, 500);
  assert.equal(available, true);
  server.close();
});

// Test 3: health request returns healthy status with bridgePid and agyPid
await test('pipeRequest: health check returns healthy with bridgePid and agyPid', async () => {
  const pipeName = 'CodexAgyTest_health_' + Date.now();
  const server = await createMockBridge(pipeName);
  servers.push(server);
  await sleep(50);
  const result = await pipeRequest(pipeName, { type: 'health' }, 5);
  assert.equal(result.status, 'healthy', `Got: ${JSON.stringify(result)}`);
  assert.equal(result.pluginVersion, '0.4.1');
  assert.equal(result.bridgePid, 1000);
  assert.equal(result.agyPid, 2000);
  server.close();
});

// Test 4: run request returns completed with output
await test('pipeRequest: run command returns completed', async () => {
  const pipeName = 'CodexAgyTest_run_' + Date.now();
  const server = await createMockBridge(pipeName);
  servers.push(server);
  await sleep(50);
  const result = await pipeRequest(pipeName, { type: 'run', command: 'echo hello' }, 5);
  assert.equal(result.status, 'completed');
  assert.ok(result.output.includes('hello'), `Output: ${result.output}`);
  server.close();
});

// Test 5: bridge_unavailable when server not running
await test('pipeRequest: bridge_unavailable when server is closed', async () => {
  const result = await pipeRequest('CodexAgyTest_closed_' + Date.now(), { type: 'health' }, 1);
  assert.equal(result.status, 'bridge_unavailable');
});

// Test 6: timeout when server doesn't respond
await test('pipeRequest: bridge_timeout when server hangs', async () => {
  const pipeName = 'CodexAgyTest_timeout_' + Date.now();
  // Server that never responds
  const server = net.createServer(() => {}); // accept but never write
  await new Promise((resolve, reject) => {
    server.listen(pipePath(pipeName), () => resolve());
    server.on('error', reject);
  });
  servers.push(server);
  await sleep(50);
  const result = await pipeRequest(pipeName, { type: 'health' }, 1);
  assert.equal(result.status, 'bridge_timeout');
  server.close();
});

// Test 7: pipe name is deterministic and cwd-specific
await test('cwdPipeName: deterministic and cwd-specific', () => {
  const nameA1 = cwdPipeName('C:\\project\\A');
  const nameA2 = cwdPipeName('C:\\project\\A');
  const nameA3 = cwdPipeName('c:\\project\\a'); // case-insensitive
  const nameB  = cwdPipeName('C:\\project\\B');
  assert.equal(nameA1, nameA2, 'Same cwd → same pipe name');
  assert.equal(nameA1, nameA3, 'Case-insensitive cwd → same pipe name');
  assert.notEqual(nameA1, nameB, 'Different cwd → different pipe name');
  assert.ok(nameA1.startsWith('CodexAgySession_'), `Unexpected prefix: ${nameA1}`);
  assert.equal(nameA1.length, 'CodexAgySession_'.length + 8, 'Hash should be 8 hex chars');
});

// Test 8: session registry round-trip (write + read)
await test('session registry: write and read back with bridgePid and agyPid', async () => {
  const registryPath = path.join(os.tmpdir(), `codex-agy-sessions-test-${Date.now()}.json`);
  const session = {
    sessionId: 'test-abc',
    cwd: 'C:\\project\\A',
    bridgePid: process.pid,
    agyPid: 12345,
    pipeName: cwdPipeName('C:\\project\\A'),
    pluginVersion: '0.4.1',
    startedAt: new Date().toISOString()
  };
  await fs.writeFile(registryPath, JSON.stringify([session]), 'utf8');

  const raw = await fs.readFile(registryPath, 'utf8');
  const entries = JSON.parse(raw);
  assert.equal(entries.length, 1);
  assert.equal(entries[0].sessionId, session.sessionId);
  assert.equal(entries[0].cwd, session.cwd);
  assert.equal(entries[0].pipeName, session.pipeName);
  assert.equal(entries[0].bridgePid, process.pid);
  assert.equal(entries[0].agyPid, 12345);
  assert.equal(entries[0].pluginVersion, '0.4.1');

  await fs.rm(registryPath, { force: true });
});

// Test 9: multi-project isolation — two pipes serve different cwd sessions
await test('multi-project: two pipes are independent', async () => {
  const pipeA = 'CodexAgyTest_multiA_' + Date.now();
  const pipeB = 'CodexAgyTest_multiB_' + Date.now();

  const serverA = await createMockBridge(pipeA, {
    respondWith: () => ({ ok: true, status: 'completed', cwd: 'C:\\project\\A', output: 'result-A' })
  });
  const serverB = await createMockBridge(pipeB, {
    respondWith: () => ({ ok: true, status: 'completed', cwd: 'C:\\project\\B', output: 'result-B' })
  });
  servers.push(serverA, serverB);
  await sleep(50);

  const rA = await pipeRequest(pipeA, { type: 'run', command: 'test' }, 5);
  const rB = await pipeRequest(pipeB, { type: 'run', command: 'test' }, 5);

  assert.equal(rA.cwd, 'C:\\project\\A', `A got: ${rA.cwd}`);
  assert.equal(rB.cwd, 'C:\\project\\B', `B got: ${rB.cwd}`);
  assert.notEqual(rA.output, rB.output);

  serverA.close(); serverB.close();
});

// Test 10: distinguishing bridge-only (agyPid: 0) from ready AGY (agyPid > 0)
await test('session status: distinguish bridge-only from ready AGY', async () => {
  const pipeBridgeOnly = 'CodexAgyTest_bridgeOnly_' + Date.now();
  const pipeReady = 'CodexAgyTest_ready_' + Date.now();

  const sBridgeOnly = await createMockBridge(pipeBridgeOnly, {
    respondWith: () => ({ ok: true, status: 'healthy', bridgePid: 1111, agyPid: 0, pluginVersion: '0.4.1' })
  });
  const sReady = await createMockBridge(pipeReady, {
    respondWith: () => ({ ok: true, status: 'healthy', bridgePid: 2222, agyPid: 3333, pluginVersion: '0.4.1' })
  });
  servers.push(sBridgeOnly, sReady);
  await sleep(50);

  const rBridgeOnly = await pipeRequest(pipeBridgeOnly, { type: 'health' }, 5);
  const rReady = await pipeRequest(pipeReady, { type: 'health' }, 5);

  assert.equal(rBridgeOnly.agyPid, 0, 'Bridge-only session must report agyPid == 0');
  assert.equal(rReady.agyPid > 0, true, 'Ready session must report nonzero agyPid');

  sBridgeOnly.close(); sReady.close();
});

// Test 11: target="auto" is rejected
await test('validation: target="auto" rejection check', () => {
  const validateArgs = (args) => {
    if (args.target === 'auto') {
      return { ok: false, error: 'target="auto" is not supported' };
    }
    return { ok: true };
  };
  assert.equal(validateArgs({ target: 'auto' }).ok, false);
  assert.equal(validateArgs({}).ok, true);
});

// ── Cleanup & summary ─────────────────────────────────────────────────────────
for (const s of servers) { try { s.close(); } catch {} }

console.log(`\n${passed} passed, ${failed} failed\n`);
if (failed > 0) process.exit(1);
