import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import readline from 'node:readline';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const serverPath = fileURLToPath(new URL('../../plugin/mcp/server.mjs', import.meta.url));
function client(temp) {
  const child = spawn(process.execPath, [serverPath], {
    env: { ...process.env, TEMP: temp, TMP: temp }, stdio: ['pipe', 'pipe', 'pipe']
  });
  const waiting = new Map();
  let nextId = 0;
  let stderr = '';
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  const input = readline.createInterface({ input: child.stdout });
  input.on('line', (line) => {
    const message = JSON.parse(line);
    const pending = waiting.get(message.id);
    if (pending) { clearTimeout(pending.timer); waiting.delete(message.id); pending.resolve(message); }
  });
  return {
    call(method, params = {}) {
      const id = ++nextId;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { waiting.delete(id); reject(new Error('RPC timeout: ' + stderr)); }, 20000);
        waiting.set(id, { resolve, timer });
        child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
      });
    },
    async close() {
      input.close();
      child.kill();
      await new Promise((resolve) => child.exitCode === null ? child.once('exit', resolve) : resolve());
      for (const value of waiting.values()) clearTimeout(value.timer);
    }
  };
}

test('actual MCP advertises open/read/wait and leaves confirmations manual by default', async () => {
  const temp = await fs.mkdtemp(path.join(os.tmpdir(), 'agy-mcp-tools-'));
  const rpc = client(temp);
  try {
    const init = await rpc.call('initialize');
    assert.equal(init.result.serverInfo.version, '0.5.0');
    const listed = await rpc.call('tools/list');
    const tools = listed.result.tools;
    for (const name of ['agy_open', 'agy_read', 'agy_wait', 'agy_status', 'agy_run', 'terminal_run']) {
      assert.ok(tools.some((tool) => tool.name === name), name);
    }
    assert.equal(tools.find((tool) => tool.name === 'agy_run').inputSchema.properties.autoApprove.default, false);
    const read = await rpc.call('tools/call', { name: 'agy_read', arguments: { cwd: temp } });
    assert.equal(read.result.structuredContent.status, 'no_session');
    assert.equal(read.result.structuredContent.inputReady, false);
    const invalidOpen = await rpc.call('tools/call', { name: 'agy_open', arguments: { cwd: path.join(temp, 'does-not-exist') } });
    assert.equal(invalidOpen.result.isError, true);
    const ping = await rpc.call('ping');
    assert.deepEqual(ping.result, {});
  } finally { await rpc.close(); await fs.rm(temp, { recursive: true, force: true }); }
});

test('actual MCP never types into a live process whose console cannot be captured', { skip: process.platform !== 'win32' }, async () => {
  const temp = await fs.mkdtemp(path.join(os.tmpdir(), 'agy-mcp-identity-'));
  const pipeName = 'CodexAgyToolsTest_' + randomUUID().replaceAll('-', '');
  const response = { status: 'healthy', cwd: temp, sessionId: 'test-session', bridgePid: process.pid, agyPid: process.pid, pipeName, pluginVersion: '0.5.0' };
  const bridge = net.createServer((socket) => {
    let buffer = '';
    socket.on('error', () => {});
    socket.on('data', (chunk) => {
      buffer += chunk;
      if (buffer.includes('\n')) { socket.end(JSON.stringify(response) + '\n'); }
    });
  });
  await new Promise((resolve, reject) => { bridge.once('error', reject); bridge.listen('\\\\.\\pipe\\' + pipeName, resolve); });
  await fs.writeFile(path.join(temp, 'codex-agy-sessions.json'), JSON.stringify([response]), 'utf8');
  const rpc = client(temp);
  try {
    const read = await rpc.call('tools/call', { name: 'agy_read', arguments: { cwd: temp } });
    assert.equal(read.result.structuredContent.status, 'capture_error');
    assert.equal(read.result.structuredContent.inputReady, false);
    const open = await rpc.call('tools/call', { name: 'agy_open', arguments: { cwd: temp } });
    assert.equal(open.result.structuredContent.reused, true);
    assert.equal(open.result.structuredContent.opened, false);
    const run = await rpc.call('tools/call', { name: 'agy_run', arguments: { cwd: temp, task: 'Do not edit anything.' } });
    assert.equal(run.result.structuredContent.submitted, false);
    assert.equal(run.result.structuredContent.status, 'capture_error');
    const wait = await rpc.call('tools/call', { name: 'agy_wait', arguments: { cwd: temp } });
    assert.equal(wait.result.structuredContent.status, 'no_pending_task');
  } finally {
    await rpc.close();
    await new Promise((resolve) => bridge.close(resolve));
    await fs.rm(temp, { recursive: true, force: true });
  }
});
