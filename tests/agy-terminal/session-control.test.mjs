import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { createSessionController, classifyScreen } from '../../plugin/mcp/session-control.mjs';

const cwd = path.join(os.tmpdir(), 'agy-authorized-project');
const session = { sessionId: 'exact-session', agyPid: 42, bridgePid: 43, pipeName: 'exact-pipe', pluginVersion: '0.5.0' };
function fixture(overrides = {}) {
  return createSessionController({
    platform: 'win32', stat: async () => ({ isDirectory: () => true }),
    findSession: async () => session, capture: async () => ({ captured: 'Shared terminal\n> \n? for shortcuts' }),
    launch: async () => { throw new Error('Unexpected new window'); },
    delay: async () => {}, isRunning: () => true, startupAttempts: 2, ...overrides
  });
}
test('screen classifies idle input, running work, and unknown startup separately', () => {
  assert.equal(classifyScreen('>\n? for shortcuts').inputReady, true);
  assert.equal(classifyScreen('Working...\nEsc to cancel\n? for shortcuts').state, 'busy');
  assert.equal(classifyScreen('Initializing').inputReady, false);
});
test('Enter, trust, yes/no and survey prompts are owned by the user', () => {
  for (const text of ['Press Enter to continue', 'Do you trust this folder?', '[y/n]', '> 1. Yes, allow', "How's the CLI experience\n[0] Skip"]) {
    const result = classifyScreen(text);
    assert.equal(result.state, 'awaiting_user', text);
    assert.equal(result.manualInputRequired, true, text);
    assert.equal(result.inputReady, false, text);
  }
  assert.equal(classifyScreen('Press Enter to send\n? for shortcuts').state, 'ready');
});
test('login screens never return visible codes or authentication URLs', () => {
  const result = classifyScreen('Login with Google\nhttps://accounts.google.com/oauth\nverification code: SECRET123');
  assert.equal(result.state, 'auth_required');
  assert.equal(result.output.includes('SECRET123'), false);
  assert.equal(result.output.includes('accounts.google.com'), false);
  assert.equal(result.manualInputRequired, true);
  assert.notEqual(classifyScreen('Review the login implementation\n? for shortcuts').state, 'auth_required');
  assert.equal(classifyScreen('You are currently not signed in.\nSigning in...' + ('\n' + ' '.repeat(120)).repeat(30)).state, 'auth_required');
});
test('read captures only the identified session without launching a terminal', async () => {
  let captures = 0;
  const controller = fixture({ capture: async (value) => {
    captures++;
    assert.equal(value, session);
    return { captured: 'Same screen as the user\n? for shortcuts' };
  } });
  const result = await controller.read({ cwd });
  assert.equal(result.sessionId, session.sessionId);
  assert.equal(result.agyPid, 42);
  assert.equal(result.inputReady, true);
  assert.equal(captures, 1);
});
test('open reuses a live AGY process, including a manual prompt', async () => {
  const result = await fixture({ capture: async () => ({ captured: 'Press Enter to continue' }) }).open({ cwd });
  assert.equal(result.opened, false);
  assert.equal(result.reused, true);
  assert.equal(result.manualInputRequired, true);
});
test('simultaneous opens create exactly one window for one project', async () => {
  let launched = false;
  let count = 0;
  const controller = fixture({
    findSession: async () => launched ? session : null,
    launch: async () => {
      count++;
      await new Promise((resolve) => setTimeout(resolve, 10));
      launched = true;
      return { hostPid: 99 };
    }
  });
  const results = await Promise.all([controller.open({ cwd }), controller.open({ cwd })]);
  assert.equal(count, 1);
  assert.equal(results[0].sessionId, results[1].sessionId);
  assert.equal(results[0].inputReady, true);
});
test('starting window is reused on another open instead of launching twice', async () => {
  let count = 0;
  const controller = fixture({ findSession: async () => null, launch: async () => { count++; return { hostPid: 99 }; } });
  assert.equal((await controller.open({ cwd })).state, 'starting');
  assert.equal((await controller.open({ cwd })).state, 'starting');
  assert.equal(count, 1);
});
test('missing bridge or missing AGY PID is not reported as input ready', async () => {
  for (const current of [null, { ...session, agyPid: 0 }]) {
    const result = await fixture({ findSession: async () => current }).read({ cwd });
    assert.equal(result.inputReady, false);
    assert.equal(result.agyReady, false);
  }
});
test('capture failure never licenses task submission', async () => {
  const result = await fixture({ capture: async () => { throw new Error('AttachConsole failed'); } }).read({ cwd });
  assert.equal(result.state, 'capture_error');
  assert.equal(result.inputReady, false);
  assert.equal(result.output, '');
});
test('capture must return actual screen text', async () => {
  assert.equal((await fixture({ capture: async () => ({}) }).read({ cwd })).status, 'capture_error');
});
test('invalid paths and limits fail without launching anything', async () => {
  const controller = fixture();
  await assert.rejects(controller.open({ cwd: 'relative-project' }), /absolute/);
  await assert.rejects(controller.open({ cwd, maxOutputChars: 0 }), /maxOutputChars/);
  await assert.rejects(fixture({ stat: async () => ({ isDirectory: () => false }) }).open({ cwd }), /existing directory/);
  await assert.rejects(fixture({ platform: 'linux' }).open({ cwd }), /only on Windows/);
});
test('output limit keeps the latest screen text', async () => {
  const result = await fixture({ capture: async () => ({ captured: 'x'.repeat(2000) + '\n? for shortcuts' }) }).read({ cwd, maxOutputChars: 1000 });
  assert.equal(result.output.length, 1000);
  assert.ok(result.output.endsWith('? for shortcuts'));
});
test('an unsent human draft is not treated as an idle input prompt', () => {
  const result = classifyScreen('>\nprevious output\n> my unsent message\n? for shortcuts');
  assert.equal(result.state, 'user_typing');
  assert.equal(result.inputReady, false);
});
