import { promises as fs } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

export function classifyScreen(value) {
  const output = typeof value === 'string' ? value.split(/\r?\n/).map((line) => line.trimEnd()).join('\n').trimEnd() : '';
  const tail = output.slice(-2000);
  if (/accounts\.google\.com|authorization\s+code|verification\s+code|(?:sign|log)\s*in\s+(?:with|to)|signing\s+in|not\s+signed\s+in|how would you like to authenticate|waiting for authentication/i.test(tail)) {
    return {
      state: 'auth_required', inputReady: false, manualInputRequired: true,
      output: '[Authentication screen hidden. Complete login yourself in the visible AGY window.]',
      action: 'Complete authentication in the AGY window, then read the terminal again.'
    };
  }
  if (/(?:press|hit)\s+(?:the\s+)?enter(?!\s+to\s+(?:send|submit))|enter\s+to\s+(?:continue|confirm|accept)|\[y\/n\]|\(y\/n\)|do you trust|trust this (?:folder|workspace)|>\s*1\.\s*(?:yes|allow|approve)|How['’]s the CLI experience[\s\S]*\[0\]\s*Skip|กด\s*enter/i.test(tail)) {
    return {
      state: 'awaiting_user', inputReady: false, manualInputRequired: true, output,
      action: 'Review the prompt and press Enter or choose an option yourself in the visible AGY window.'
    };
  }
  if (/esc(?:ape)?\s+to\s+(?:cancel|interrupt)|(?:thinking|generating|working)\.{2,}/i.test(tail)) {
    return { state: 'busy', inputReady: false, manualInputRequired: false, output, action: 'Wait for the current operation to finish.' };
  }
  const prompts = [...tail.matchAll(/^[ \t]*[>›❯][ \t]*([^\r\n]*)$/gm)];
  if (prompts.length && prompts.at(-1)[1].trim()) {
    return {
      state: 'user_typing', inputReady: false, manualInputRequired: false, output,
      action: 'The terminal contains an unsent draft. Let the user finish before submitting a task.'
    };
  }
  const inputReady = /\?\s+for shortcuts|type (?:your |a )?message|^\s*[>›❯]\s*$/im.test(tail);
  return {
    state: inputReady ? 'ready' : 'starting', inputReady, manualInputRequired: false, output,
    action: inputReady ? null : 'Read the terminal again after startup completes.'
  };
}

export function createSessionController({
  findSession, launch, capture,
  platform = process.platform,
  stat = fs.stat,
  delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  isRunning = (pid) => { try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; } },
  startupAttempts = 40
}) {
  const opening = new Map();
  const windows = new Map();

  async function directory(args) {
    const cwd = args.cwd ?? process.cwd();
    if (typeof cwd !== 'string' || !path.isAbsolute(cwd)) throw new Error('cwd must be an absolute directory path.');
    const resolved = path.resolve(cwd);
    if (!(await stat(resolved)).isDirectory()) throw new Error('cwd must be an existing directory.');
    return resolved;
  }

  function maxChars(args) {
    const limit = args.maxOutputChars ?? 12000;
    if (!Number.isInteger(limit) || limit < 1000 || limit > 100000) throw new Error('maxOutputChars must be between 1000 and 100000.');
    return limit;
  }

  async function observe(session, cwd, limit) {
    const base = {
      cwd, sessionId: session.sessionId, bridgePid: session.bridgePid,
      agyPid: session.agyPid, pipeName: session.pipeName, pluginVersion: session.pluginVersion,
      ready: true, agyReady: true
    };
    try {
      const screen = await capture(session);
      if (typeof screen?.captured !== 'string') throw new Error('Console capture returned no screen text.');
      const observation = classifyScreen(screen.captured);
      return { ...base, status: 'observed', ...observation, output: observation.output.slice(-limit) };
    } catch (e) {
      return {
        ...base, status: 'capture_error', state: 'capture_error', inputReady: false,
        manualInputRequired: false, output: '', error: e.message,
        action: 'The AGY process exists, but its screen could not be read. Keep the visible window open; do not send a task until capture works.'
      };
    }
  }

  async function read(args = {}) {
    const cwd = await directory(args);
    const limit = maxChars(args);
    const session = await findSession(cwd);
    if (!session || !(session.agyPid > 0)) {
      return {
        status: 'no_session', state: session ? 'bridge_only' : 'no_session',
        cwd, ready: Boolean(session), agyReady: false, inputReady: false,
        manualInputRequired: false, output: '', action: 'Call agy_open for this directory.'
      };
    }
    return observe(session, cwd, limit);
  }

  async function openOnce(cwd, limit) {
    const existing = await findSession(cwd);
    if (existing?.agyPid > 0) return { ...await observe(existing, cwd, limit), opened: false, reused: true };
    const key = cwd.toLowerCase();
    let window = windows.get(key);
    if (!window || !isRunning(window.hostPid)) {
      window = await launch(cwd);
      windows.set(key, window);
    }
    for (let attempt = 0; attempt < startupAttempts; attempt++) {
      const session = await findSession(cwd);
      if (session?.agyPid > 0) {
        windows.delete(key);
        return { ...await observe(session, cwd, limit), hostPid: window.hostPid, opened: true, reused: false };
      }
      if (!isRunning(window.hostPid)) throw new Error('The visible terminal exited before AGY registered. Check the launcher or Windows application-control policy.');
      await delay(250);
    }
    return {
      status: 'starting', state: 'starting', cwd, hostPid: window.hostPid,
      opened: true, ready: false, agyReady: false, inputReady: false,
      manualInputRequired: false, output: '', action: 'The window is open. Read it again after startup; do not launch a duplicate.'
    };
  }

  async function open(args = {}) {
    if (platform !== 'win32') throw new Error('Opening a visible AGY console is supported only on Windows.');
    const cwd = await directory(args);
    const limit = maxChars(args);
    const key = cwd.toLowerCase();
    if (opening.has(key)) return opening.get(key);
    const pending = openOnce(cwd, limit);
    opening.set(key, pending);
    try { return await pending; } finally { opening.delete(key); }
  }

  return { open, read };
}
