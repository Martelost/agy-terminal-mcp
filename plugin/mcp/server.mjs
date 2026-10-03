/**
 * agy-terminal MCP server  —  v0.5.0
 *
 * Protocol: JSON-RPC 2.0 over stdio (MCP 2025-06-18)
 *
 * Tools
 *   agy_run     Send a bounded task to the user-opened AGY terminal.
 *   agy_status  Report the session status for a given cwd.
 *   terminal_run Run a raw PowerShell command in the bridge terminal.
 *
 * Changes from v0.4.0
 *   - Separate bridgePid vs agyPid in session registry.
 *   - visibleTerminalRequest passes -SessionId to agy-visible-input.ps1;
 *     no process-name fallback allowed.
 *   - findSession returns health response (includes agyPid) for caller use.
 *   - agy_status reports bridgePid and agyPid.
 *   - agyPid==0 → no_agy_pid error with clear hint to wait for agy to start.
 */

import net from 'node:net';
import { spawn } from 'node:child_process';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import readline from 'node:readline';
import { randomUUID, createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { createSessionController } from './session-control.mjs';

const SERVER_NAME = 'agy-terminal';
const SERVER_VERSION = '0.5.0';
const PROTOCOL_VERSION = '2025-06-18';
const DEFAULT_TIMEOUT_SECONDS = 900;
const DEFAULT_MAX_OUTPUT_CHARS = 30000;
const SERVER_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const VISIBLE_INPUT_SCRIPT = path.join(SERVER_DIRECTORY, 'agy-visible-input.ps1');
const BRIDGE_SCRIPT = path.join(SERVER_DIRECTORY, 'agy-terminal-bridge.ps1');
const SESSION_REGISTRY = path.join(os.tmpdir(), 'codex-agy-sessions.json');
const OPEN_SCRIPT = path.join(SERVER_DIRECTORY, 'agy-open.ps1');
const pendingTasks = new Map();

// ── Tool definitions ──────────────────────────────────────────────────────────

const agyStatusTool = {
  name: 'agy_status',
  description: [
    'Report whether an AGY terminal session is ready for the given cwd.',
    'Returns: ready flag, agyReady flag, cwd, sessionId, serverVersion, pipeName, bridgePid, agyPid, state, and actionable reason if unavailable.',
    'Always call this before agy_run to verify that agyReady is true and agyPid is non-zero.'
  ].join(' '),
  inputSchema: {
    type: 'object',
    additionalProperties: false,
    properties: {
      cwd: {
        type: 'string',
        description: 'Absolute workspace directory to check. Defaults to the MCP server process cwd.'
      }
    },
    required: []
  }
};

const agyRunTool = {
  name: 'agy_run',
  description: [
    'Send a bounded task to the visible AGY terminal in the project directory.',
    'Requires calling agy_status first to verify both ready: true and agyReady: true with a nonzero agyPid.',
    'The user confirms operations by default. Explicit autoApprove:true in worker mode permits ONLY scoped file-edit confirmations.',
    'Shell commands, OAuth, login, delete, and out-of-scope files are never auto-approved.',
    'In review mode (default) AGY is read-only.',
    'Returns the captured AGY response, autoApproval count, blocked count, and session metadata.',
    'Use agy_open to open a visible session and agy_read to inspect it first. Use agy_wait after a human handles a pending task confirmation. Target parameter must be omitted.'
  ].join(' '),
  inputSchema: {
    type: 'object',
    additionalProperties: false,
    properties: {
      task: {
        type: 'string',
        minLength: 1,
        description: 'Bounded task description to send to AGY.'
      },
      prompt: {
        type: 'string',
        minLength: 1,
        description: 'Alias for task (backward compatibility).'
      },
      mode: {
        type: 'string',
        enum: ['review', 'worker'],
        description: 'review is read-only (default); worker allows scoped file edits.'
      },
      cwd: {
        type: 'string',
        description: 'Absolute workspace directory. Used to match the correct AGY session.'
      },
      editableFiles: {
        type: 'array',
        items: { type: 'string' },
        description: 'Required for worker mode. Absolute paths of files AGY may edit. Must be inside cwd.'
      },
      timeoutSeconds: {
        type: 'integer',
        minimum: 15,
        maximum: 3600,
        description: 'Timeout in seconds. Default 900 (15 min).'
      },
      timeoutMs: {
        type: 'integer',
        minimum: 15000,
        maximum: 3600000,
        description: 'Timeout in milliseconds (alternative to timeoutSeconds).'
      },
      maxOutputChars: {
        type: 'integer',
        minimum: 1000,
        maximum: 100000,
        description: 'Maximum output characters returned. Default 30000.'
      }
    },
    required: []
  }
};

const terminalRunTool = {
  name: 'terminal_run',
  description: [
    'Run a PowerShell command in the user-opened AGY terminal bridge and return its output.',
    'Use only when the user explicitly requests a PowerShell command in the visible terminal.',
    'Never use this tool automatically from agy_run; it is for direct user-authorized commands only.',
    'Never send secrets or authorization codes through this tool.'
  ].join(' '),
  inputSchema: {
    type: 'object',
    additionalProperties: false,
    properties: {
      command: {
        type: 'string',
        minLength: 1,
        description: 'PowerShell command to run in the bridge terminal.'
      },
      cwd: {
        type: 'string',
        description: 'Optional absolute directory for this command.'
      },
      timeoutSeconds: {
        type: 'integer',
        minimum: 15,
        maximum: 3600,
        description: 'Maximum wait time in seconds. Default 900.'
      },
      maxOutputChars: {
        type: 'integer',
        minimum: 1000,
        maximum: 100000,
        description: 'Maximum output characters returned. Default 30000.'
      }
    },
    required: ['command']
  }
};

const agyOpenTool = {
  name: 'agy_open',
  description: 'Open AGY yourself in a visible, user-interactive console for the authorized project. Reuse an existing session. Return the actual terminal screen and whether the user must handle a prompt. Never confirms prompts or logs in.',
  inputSchema: {
    type: 'object', additionalProperties: false,
    properties: {
      cwd: { type: 'string', description: 'Absolute project directory.' },
      maxOutputChars: { type: 'integer', minimum: 1000, maximum: 100000 }
    }
  }
};
const agyReadTool = {
  name: 'agy_read',
  description: 'Read the visible AGY terminal for this project without typing or pressing Enter. Return screen text, inputReady, and manualInputRequired. Authentication screens are hidden; the user handles login.',
  inputSchema: agyOpenTool.inputSchema
};
const agyWaitTool = {
  name: 'agy_wait',
  description: 'Continue observing a previously submitted task after the user handles a terminal confirmation. Does not resend the task or press Enter. Use agy_read to inspect the current screen.',
  inputSchema: {
    type: 'object', additionalProperties: false,
    properties: {
      cwd: { type: 'string', description: 'Absolute project directory.' },
      timeoutSeconds: { type: 'integer', minimum: 15, maximum: 3600 },
      maxOutputChars: { type: 'integer', minimum: 1000, maximum: 100000 }
    }
  }
};
agyRunTool.inputSchema.properties.autoApprove = {
  type: 'boolean',
  default: false,
  description: 'Default false: the user confirms operations in the visible terminal. True explicitly enables only scoped file-edit approvals in worker mode.'
};

// ── JSON-RPC helpers ──────────────────────────────────────────────────────────

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function rpcResult(id, result) {
  return { jsonrpc: '2.0', id, result };
}

function rpcError(id, code, message, data) {
  const response = { jsonrpc: '2.0', id, error: { code, message } };
  if (data !== undefined) response.error.data = data;
  return response;
}

function textResult(text, structured, isError = false) {
  return {
    content: [{ type: 'text', text }],
    structuredContent: structured,
    isError
  };
}

function trimOutput(value, maxChars) {
  if (!value) return '';
  if (value.length <= maxChars) return value;
  return `${value.slice(0, maxChars)}\n...[truncated ${value.length - maxChars} chars]`;
}

// Small helper processes use a result file because AttachConsole changes console
// handles. No AGY stdin/stdout is redirected; the user owns the visible console.
async function powershellResult(script, args, timeoutMs = 15000) {
  const resultFile = path.join(os.tmpdir(), 'codex-agy-observation-' + randomUUID() + '.json');
  try {
    await new Promise((resolve, reject) => {
      const child = spawn('powershell.exe', [
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script,
        ...args, '-ResultFile', resultFile
      ], { windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] });
      let error = '';
      const timer = setTimeout(() => { child.kill(); reject(new Error('Console helper timed out.')); }, timeoutMs);
      child.stderr.on('data', (chunk) => { error = (error + chunk.toString()).slice(-3000); });
      child.once('error', (e) => { clearTimeout(timer); reject(e); });
      child.once('close', (code) => {
        clearTimeout(timer);
        if (code === 0) resolve();
        else reject(new Error(error.trim() || 'Console helper exited with code ' + code));
      });
    });
    return JSON.parse((await fs.readFile(resultFile, 'utf8')).replace(/^\uFEFF/, ''));
  } finally { await fs.rm(resultFile, { force: true }).catch(() => {}); }
}

const sessionController = createSessionController({
  findSession,
  launch: (cwd) => powershellResult(OPEN_SCRIPT, ['-Cwd', cwd, '-PipeName', cwdPipeName(cwd)]),
  capture: (session) => powershellResult(VISIBLE_INPUT_SCRIPT, [
    '-ReadOnly', '-SessionId', session.sessionId, '-AgyPid', String(session.agyPid)
  ])
});

// ── Session registry ──────────────────────────────────────────────────────────

function cwdPipeName(cwd) {
  const hash = createHash('sha256')
    .update(cwd.toLowerCase())
    .digest('hex')
    .slice(0, 8);
  return `CodexAgySession_${hash}`;
}

async function readRegistry() {
  try {
    const raw = await fs.readFile(SESSION_REGISTRY, 'utf8');
    const parsed = JSON.parse(raw.replace(/^\uFEFF/, ''));
    return Array.isArray(parsed) ? parsed : [parsed];
  } catch {
    return [];
  }
}

function isPidRunning(pid) {
  if (!pid || !Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === 'EPERM';
  }
}

/**
 * Find a live session for the given cwd.
 * Returns the registry entry with health check data or null.
 * Filters out dead bridge processes and evaluates newest entries first.
 */
async function findSession(cwd) {
  const entries = await readRegistry();
  const normalized = cwd ? path.resolve(cwd).toLowerCase() : null;

  // Filter out entries whose bridge process has already exited
  const activeEntries = [];
  for (const entry of entries) {
    if (!entry || !entry.cwd || !entry.pipeName) continue;
    const bPid = entry.bridgePid ?? entry.pid;
    if (bPid && !isPidRunning(bPid)) continue;
    activeEntries.push(entry);
  }

  // Evaluate newest entries first to connect to the most recent session
  for (let i = activeEntries.length - 1; i >= 0; i--) {
    const entry = activeEntries[i];
    const entryCwd = path.resolve(entry.cwd).toLowerCase();
    if (normalized && entryCwd !== normalized) continue;

    const health = await pipeHealthCheck(entry.pipeName, 2);
    if (health) {
      return { ...entry, ...health };
    }
  }
  return null;
}

// ── Named pipe helpers ────────────────────────────────────────────────────────

function pipePath(pipeName) {
  if (process.platform === 'win32') return `\\\\.\\pipe\\${pipeName}`;
  return path.join('/tmp', `${pipeName}.sock`);
}

async function pipeHealthCheck(pipeName, timeoutSeconds = 2) {
  try {
    const result = await pipeRequest(pipeName, { type: 'health' }, timeoutSeconds);
    return result && result.status === 'healthy' ? result : null;
  } catch {
    return null;
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function pipeRequest(pipeName, payload, timeoutSeconds) {
  return new Promise((resolve) => {
    let settled = false;
    let buffer = '';
    const socket = net.createConnection(pipePath(pipeName));
    const timer = setTimeout(() => finish({
      status: 'bridge_timeout',
      error: `No response from pipe '${pipeName}' within ${timeoutSeconds}s.`,
      output: ''
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
        const normalized = line.replace(/^\uFEFF/, '');
        if (!normalized.trim()) continue;
        try { finish(JSON.parse(normalized)); }
        catch (e) { finish({ status: 'bridge_protocol_error', error: e.message, output: normalized }); }
      }
    });
    socket.on('error', (e) => finish({
      status: 'bridge_unavailable',
      error: `Pipe '${pipeName}' not reachable: ${e.message}`,
      output: ''
    }));
    socket.on('close', () => {
      if (!settled) finish({
        status: 'bridge_disconnected',
        error: 'Bridge disconnected before responding.',
        output: buffer
      });
    });
  });
}

// ── Per-session queue ─────────────────────────────────────────────────────────
// Prevents two concurrent tasks from typing over each other in the same terminal.

const sessionQueues = new Map(); // pipeName → Promise (tail of queue chain)

function enqueueForSession(pipeName, fn) {
  const prev = sessionQueues.get(pipeName) ?? Promise.resolve();
  const next = prev.catch(() => {}).then(fn); // never execute a failed task twice
  sessionQueues.set(pipeName, next.catch(() => {}));
  return next;
}

// ── Visible terminal interaction ──────────────────────────────────────────────

async function visibleTerminalRequest({ text = '', timeoutSeconds, autoApprove, sessionId, agyPid, cwd, editableFiles, ticket, observeOnly = false }) {
  const token = randomUUID().replaceAll('-', '');
  const beginMarker = ticket.beginMarker;
  const endMarker = ticket.endMarker;
  const resultFile = path.join(os.tmpdir(), `codex-agy-result-${process.pid}-${token}.json`);
  const promptFile = path.join(os.tmpdir(), `codex-agy-prompt-${process.pid}-${token}.txt`);

  const prompt = [
    text,
    '',
    'When finished, print a concise final answer for Codex between these exact markers.',
    beginMarker,
    '<concise final answer>',
    endMarker,
    'Do not omit the end marker.'
  ].join('\n');

  if (!observeOnly) await fs.writeFile(promptFile, prompt, 'utf8');

  return new Promise((resolve) => {
    let settled = false;
    let senderOutput = '';
    let captureError = '';

    const inputArgs = [
      '-NoLogo',
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', VISIBLE_INPUT_SCRIPT,
      '-CompletionMarker', endMarker,
      '-WaitSeconds', String(timeoutSeconds),
      '-ResultFile', resultFile
    ];
    if (observeOnly) inputArgs.push('-ObserveOnly');
    else inputArgs.push('-PromptFile', promptFile);
    if (sessionId) inputArgs.push('-SessionId', sessionId);
    if (agyPid) inputArgs.push('-AgyPid', String(agyPid));
    if (autoApprove) inputArgs.push('-AutoApprove');
    if (cwd) inputArgs.push('-Cwd', cwd);
    if (editableFiles && editableFiles.length > 0) {
      inputArgs.push('-EditableFilesJson', JSON.stringify(editableFiles));
    }

    const child = spawn('powershell.exe', inputArgs, {
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe']
    });

    const cleanup = async () => {
      await Promise.all([
        fs.rm(resultFile, { force: true }).catch(() => {}),
        fs.rm(promptFile, { force: true }).catch(() => {})
      ]);
    };

    const finish = async (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      await cleanup();
      resolve(result);
    };

    const extractAnswer = (captured) => {
      const raw = typeof captured === 'string' ? captured : '';
      const begin = raw.lastIndexOf(beginMarker);
      const end = raw.indexOf(endMarker, begin >= 0 ? begin + beginMarker.length : 0);
      if (begin >= 0 && end > begin) return raw.slice(begin + beginMarker.length, end).trim();
      if (end >= 0) return raw.slice(Math.max(0, end - 12000), end).trim();
      return raw.trim();
    };

    const loadResult = async () => {
      try {
        const fileText = await fs.readFile(resultFile, 'utf8');
        return JSON.parse(fileText.replace(/^\uFEFF/, ''));
      } catch { return null; }
    };

    const timeout = setTimeout(() => {
      child.kill();
      finish({
        status: 'visible_terminal_timeout',
        exitCode: null,
        output: senderOutput,
        error: `Could not submit or complete the task within ${timeoutSeconds} seconds.`
      });
    }, (timeoutSeconds + 10) * 1000);

    child.stdout.on('data', (chunk) => { senderOutput += chunk.toString(); });
    child.stderr.on('data', (chunk) => { captureError += chunk.toString(); });
    child.on('error', (e) => finish({
      status: 'visible_terminal_unavailable',
      exitCode: null,
      output: senderOutput,
      error: e.message
    }));
    child.on('close', async (exitCode) => {
      const captured = await loadResult();
      const captureStatus = captured?.status || (exitCode === 0
        ? 'submitted_to_visible_terminal'
        : 'visible_terminal_error');
      finish({
        status: captureStatus === 'completed' ? 'completed_visible_terminal' : captureStatus,
        submitted: !observeOnly,
        exitCode,
        output: captured ? extractAnswer(captured.captured) : senderOutput,
        rawOutput: captured?.captured || '',
        autoApprovals: captured?.autoApprovals || 0,
        blocked: captured?.blocked || 0,
        error: captured?.error || captureError
      });
    });
  });
}

// ── Prompt builder ────────────────────────────────────────────────────────────

function buildAgyPrompt({ prompt, mode, editableFiles }) {
  const scope = mode === 'worker'
    ? `This is a bounded implementation task. Edit only these files: ${editableFiles.join(', ')}`
    : 'This is a read-only review. Do not edit files.';

  const workerGuard = mode === 'worker'
    ? [
        'Use only file-reading and file-editing tools.',
        'Do not use RunCommand, Bash, PowerShell, terminal, or any shell command.',
        'Do not read .env, secrets, credentials, authentication tokens, or participant data.',
        'The primary Codex agent will run validation after reviewing your diff.'
      ].join(' ')
    : '';

  return [
    'Read GEMINI.md in the workspace root first and follow it.',
    'Read the applicable AGENTS.md and the smallest relevant skill set completely before acting.',
    'Do not use credentials, access production data, inspect participant responses, deploy, publish, or perform external side effects.',
    scope,
    workerGuard,
    `Task: ${prompt}`,
    'Report changed files and validation results. The primary Codex agent will review the result.'
  ].filter(Boolean).join('\n\n');
}

// ── Tool validation ───────────────────────────────────────────────────────────

function validateLimits(args) {
  let timeoutSeconds;
  if (Number.isInteger(args.timeoutSeconds)) {
    timeoutSeconds = args.timeoutSeconds;
  } else if (Number.isInteger(args.timeoutMs)) {
    timeoutSeconds = Math.round(args.timeoutMs / 1000);
  } else {
    timeoutSeconds = DEFAULT_TIMEOUT_SECONDS;
  }
  const maxOutputChars = Number.isInteger(args.maxOutputChars)
    ? args.maxOutputChars
    : DEFAULT_MAX_OUTPUT_CHARS;
  if (timeoutSeconds < 15 || timeoutSeconds > 3600) throw new Error('timeout must be between 15s and 3600s');
  if (maxOutputChars < 1000 || maxOutputChars > 100000) throw new Error('maxOutputChars must be between 1000 and 100000');
  return { timeoutSeconds, maxOutputChars };
}

// ── Tool handlers ─────────────────────────────────────────────────────────────

async function handleAgyStatus(requestId, args) {
  const cwd = (typeof args.cwd === 'string' && args.cwd.trim()) ? args.cwd.trim() : process.cwd();
  const expectedPipe = cwdPipeName(path.resolve(cwd));

  // findSession returns the health response object (has bridgePid, agyPid) or null
  const health = await findSession(cwd);
  const ready = health !== null;
  const agyPid = (ready && Number.isInteger(health.agyPid) && health.agyPid > 0) ? health.agyPid : 0;
  let agyReady = ready && agyPid > 0;
  let observation = null;
  if (agyReady) {
    try { observation = await sessionController.read({ cwd }); }
    catch (e) { observation = { state: 'capture_error', inputReady: false, action: e.message }; }
    agyReady = observation.inputReady === true;
  }

  let state = 'no_session';
  let reason = null;
  let action = null;

  if (!ready) {
    state = 'no_session';
    reason = `No active AGY session found for cwd '${cwd}'.`;
    action = 'Call agy_open with this project directory to open a visible AGY window.';
  } else if (!agyPid) {
    state = 'bridge_only';
    reason = `Bridge is connected (bridgePid: ${health.bridgePid}), but agy.exe is not active (agyPid: 0).`;
    action = `Run 'agy' in the project terminal. If authentication is needed, complete interactive OAuth/login in that terminal window. Wait for the AGY prompt, then re-check agy_status.`;
  } else if (observation && !observation.inputReady) {
    state = observation.state;
    reason = 'The AGY window exists but is not ready for a new task.';
    action = observation.action;
  } else {
    state = 'ready';
    reason = null;
    action = null;
  }

  const structured = {
    state,
    ready,
    agyReady,
    cwd,
    sessionId: health?.sessionId ?? null,
    pipeName: health?.pipeName ?? expectedPipe,
    serverVersion: SERVER_VERSION,
    pluginVersion: health?.pluginVersion ?? null,
    bridgePid: health?.bridgePid ?? null,
    agyPid,
    inputReady: observation?.inputReady ?? false,
    manualInputRequired: observation?.manualInputRequired ?? false,
    startedAt: health?.startedAt ?? null,
    reason,
    action
  };

  const text = [
    `state: ${state}`,
    `ready: ${ready}`,
    `agyReady: ${agyReady}`,
    `cwd: ${cwd}`,
    `sessionId: ${structured.sessionId ?? '(none)'}`,
    `pipe: ${structured.pipeName}`,
    `serverVersion: ${SERVER_VERSION}`,
    `pluginVersion: ${structured.pluginVersion ?? '(unknown)'}`,
    `bridgePid: ${structured.bridgePid ?? '(none)'}`,
    `agyPid: ${agyPid}`,
    reason ? `reason: ${reason}` : '',
    action ? `action: ${action}` : ''
  ].filter(Boolean).join('\n');

  return rpcResult(requestId, textResult(text, structured, !agyReady));
}

async function handleAgyRun(requestId, args) {
  let limits;
  try { limits = validateLimits(args); }
  catch (e) { return rpcResult(requestId, textResult(e.message, { status: 'invalid_input' }, true)); }

  // Reject legacy target="auto"
  if (args.target === 'auto') {
    return rpcResult(requestId, textResult(
      'target="auto" is not supported in agy-terminal v0.4.1. Omit the target parameter; the visible terminal is always used.',
      { status: 'unsupported_target', serverVersion: SERVER_VERSION },
      true
    ));
  }

  // Resolve task/prompt (support "task" as primary, "prompt" as alias)
  const prompt = (typeof args.task === 'string' && args.task.trim())
    ? args.task.trim()
    : (typeof args.prompt === 'string' ? args.prompt.trim() : '');
  if (!prompt) {
    return rpcResult(requestId, textResult(
      '"task" is required.',
      { status: 'invalid_input', serverVersion: SERVER_VERSION },
      true
    ));
  }

  const mode = args.mode ?? 'review';
  if (!['review', 'worker'].includes(mode)) {
    return rpcResult(requestId, textResult('mode must be "review" or "worker".',
      { status: 'invalid_input' }, true));
  }

  const editableFiles = Array.isArray(args.editableFiles)
    ? args.editableFiles.filter((f) => typeof f === 'string' && f.trim())
    : [];

  if (mode === 'worker' && editableFiles.length === 0) {
    return rpcResult(requestId, textResult(
      'editableFiles is required for worker mode.',
      { status: 'invalid_input', serverVersion: SERVER_VERSION },
      true
    ));
  }

  const cwd = (typeof args.cwd === 'string' && args.cwd.trim()) ? args.cwd.trim() : null;

  // ── Locate active session ─────────────────────────────────────────────────
  // findSession returns the health response (bridgePid, agyPid) or null
  const session = await findSession(cwd ?? process.cwd());
  if (!session) {
    const targetCwd = cwd ?? process.cwd();
    const msg = [
      `No active AGY session found for cwd '${targetCwd}'.`,
      'Call agy_open with that project directory, inspect agy_read, then retry when inputReady is true.'
    ].join(' ');
    return rpcResult(requestId, textResult(msg, {
      status: 'no_session',
      cwd: targetCwd,
      serverVersion: SERVER_VERSION
    }, true));
  }

  // agyPid must be > 0: the bridge detected an agy.exe in the same terminal
  const agyPid = Number(session.agyPid);
  if (!agyPid || agyPid <= 0) {
    return rpcResult(requestId, textResult(
      `Session found for '${session.cwd}' but agyPid is 0 (bridge is active, but agy.exe is not running). ` +
      `Run 'agy' in the project terminal. If authentication is needed, complete the interactive OAuth/login prompt in that terminal. ` +
      `Call agy_status to confirm agyReady: true before retrying agy_run.`,
      {
        status: 'no_agy_pid',
        state: 'bridge_only',
        sessionId: session.sessionId,
        cwd: session.cwd,
        bridgePid: session.bridgePid ?? null,
        agyPid: 0,
        serverVersion: SERVER_VERSION
      },
      true
    ));
  }

  if (args.autoApprove !== undefined && typeof args.autoApprove !== 'boolean') {
    return rpcResult(requestId, textResult('autoApprove must be a boolean.', { status: 'invalid_input' }, true));
  }
  if (args.autoApprove === true && mode !== 'worker') {
    return rpcResult(requestId, textResult('autoApprove is available only in worker mode.', { status: 'invalid_input' }, true));
  }
  if (editableFiles.some((file) => !path.isAbsolute(file) ||
      path.relative(path.resolve(session.cwd), path.resolve(file)).startsWith('..') ||
      path.isAbsolute(path.relative(path.resolve(session.cwd), path.resolve(file))))) {
    return rpcResult(requestId, textResult('editableFiles must be absolute paths inside cwd.', { status: 'invalid_input' }, true));
  }
  const agPrompt = buildAgyPrompt({ prompt, mode, editableFiles });
  const { timeoutSeconds, maxOutputChars } = limits;

  // ── Queue the request for this session ────────────────────────────────────
  const result = await enqueueForSession(session.pipeName, async () => {
    if (pendingTasks.has(session.sessionId)) {
      return { status: 'pending_task', submitted: false, error: 'A task is already pending in this terminal. Use agy_read or agy_wait; do not resend it.' };
    }
    const observation = await sessionController.read({ cwd: session.cwd });
    if (!observation.inputReady) {
      return { status: observation.state, submitted: false, output: observation.output, error: observation.action };
    }
    const token = randomUUID().replaceAll('-', '');
    const ticket = { beginMarker: 'CODEX_AGY_RESULT_BEGIN_' + token, endMarker: 'CODEX_AGY_RESULT_END_' + token };
    const pending = { ticket, sessionId: session.sessionId, agyPid: session.agyPid, cwd: session.cwd, editableFiles, autoApprove: args.autoApprove === true };
    pendingTasks.set(session.sessionId, pending);
    const captured = await visibleTerminalRequest({
      text: agPrompt,
      timeoutSeconds,
      autoApprove: pending.autoApprove,
      sessionId: session.sessionId,   // v0.4.1: passed directly, no process-name fallback
      agyPid: session.agyPid,         // v0.4.1: passed directly
      cwd: session.cwd,
      editableFiles,
      ticket
    });
    if (captured.status === 'completed_visible_terminal') pendingTasks.delete(session.sessionId);
    return captured;
  });

  const output = typeof result.output === 'string' ? result.output.trim() : '';
  const error = typeof result.error === 'string' ? result.error.trim() : '';
  const succeeded = ['completed_visible_terminal', 'submitted_to_visible_terminal'].includes(result.status);

  const text = [
    `status: ${result.status}`,
    `exitCode: ${result.exitCode ?? 'null'}`,
    `session: ${session.sessionId}`,
    `cwd: ${session.cwd}`,
    `serverVersion: ${SERVER_VERSION}`,
    `autoApprovals: ${result.autoApprovals ?? 0}`,
    `blocked: ${result.blocked ?? 0}`,
    result.status === 'completed_visible_terminal'
      ? 'Response captured from the visible AGY terminal.'
      : result.submitted === false ? 'No new input was sent to the terminal.' : 'Prompt submitted to the visible AGY terminal.',
    output ? `--- agy response ---\n${trimOutput(output, maxOutputChars)}` : '',
    error ? `--- capture error ---\n${trimOutput(error, maxOutputChars)}` : ''
  ].filter(Boolean).join('\n');

  return rpcResult(requestId, textResult(text, {
    status: result.status,
    submitted: result.submitted ?? false,
    manualInputRequired: ['awaiting_user', 'auth_required'].includes(result.status),
    exitCode: result.exitCode ?? null,
    sessionId: session.sessionId,
    cwd: session.cwd,
    serverVersion: SERVER_VERSION,
    autoApprovals: result.autoApprovals ?? 0,
    blocked: result.blocked ?? 0,
    output: trimOutput(output, maxOutputChars),
    error: trimOutput(error, maxOutputChars)
  }, !succeeded));
}

async function handleTerminalRun(requestId, args) {
  let limits;
  try { limits = validateLimits(args); }
  catch (e) { return rpcResult(requestId, textResult(e.message, { status: 'invalid_input' }, true)); }

  const command = typeof args.command === 'string' ? args.command.trim() : '';
  if (!command) {
    return rpcResult(requestId, textResult('command is required', { status: 'invalid_input' }, true));
  }

  const cwd = (typeof args.cwd === 'string' && args.cwd.trim()) ? args.cwd.trim() : null;
  const session = await findSession(cwd ?? process.cwd());
  if (!session) {
    const targetCwd = cwd ?? process.cwd();
    return rpcResult(requestId, textResult(
      `No bridge session for cwd '${targetCwd}'. Run 'agy' in that terminal first.`,
      { status: 'no_session', cwd: targetCwd, serverVersion: SERVER_VERSION },
      true
    ));
  }

  const payload = { type: 'run', command, cwd: cwd ?? null };
  let result = await pipeRequest(session.pipeName, payload, limits.timeoutSeconds);

  // Retry once on race between probe and new pipe instance
  for (let i = 0; i < 3 && result.status === 'bridge_unavailable'; i++) {
    await sleep(400);
    result = await pipeRequest(session.pipeName, payload, limits.timeoutSeconds);
  }

  const output = typeof result.output === 'string' ? result.output : '';
  const error = typeof result.error === 'string' ? result.error : '';
  const status = result.status || (result.ok ? 'completed' : 'failed');

  const text = [
    `status: ${status}`,
    `exitCode: ${result.exitCode ?? 'null'}`,
    `sessionId: ${result.sessionId ?? session.sessionId}`,
    `cwd: ${result.cwd ?? session.cwd}`,
    `serverVersion: ${SERVER_VERSION}`,
    '--- terminal output ---',
    trimOutput(output, limits.maxOutputChars),
    error ? `--- bridge error ---\n${trimOutput(error, limits.maxOutputChars)}` : ''
  ].filter(Boolean).join('\n');

  return rpcResult(requestId, textResult(text, {
    status,
    exitCode: result.exitCode ?? null,
    sessionId: result.sessionId ?? session.sessionId,
    cwd: result.cwd ?? session.cwd,
    serverVersion: SERVER_VERSION,
    output: trimOutput(output, limits.maxOutputChars),
    error: trimOutput(error, limits.maxOutputChars)
  }, status !== 'completed'));
}

async function handleSessionControl(requestId, args, operation) {
  try {
    const observation = await sessionController[operation](args);
    const structured = { ...observation, serverVersion: SERVER_VERSION };
    const text = [
      'state: ' + observation.state,
      'cwd: ' + observation.cwd,
      'inputReady: ' + Boolean(observation.inputReady),
      'manualInputRequired: ' + Boolean(observation.manualInputRequired),
      observation.action ? 'action: ' + observation.action : '',
      observation.output ? '--- visible AGY screen ---\n' + observation.output : ''
    ].filter(Boolean).join('\n');
    return rpcResult(requestId, textResult(text, structured, ['capture_error', 'no_session'].includes(observation.status)));
  } catch (e) {
    return rpcResult(requestId, textResult(e.message, { status: 'terminal_error', serverVersion: SERVER_VERSION }, true));
  }
}

async function handleAgyWait(requestId, args) {
  try {
    const limits = validateLimits(args);
    const observation = await sessionController.read(args);
    const pending = pendingTasks.get(observation.sessionId);
    if (!pending) return rpcResult(requestId, textResult('No pending task for this session. Use agy_read to inspect the screen.', { status: 'no_pending_task' }, true));
    if (observation.manualInputRequired || observation.status === 'capture_error') {
      return rpcResult(requestId, textResult(observation.action, observation, true));
    }
    const session = await findSession(observation.cwd);
    if (!session || session.sessionId !== pending.sessionId || session.agyPid !== pending.agyPid) {
      return rpcResult(requestId, textResult('The original task session changed. Read the terminal before continuing.', { status: 'session_changed' }, true));
    }
    const result = await enqueueForSession(session.pipeName, () => visibleTerminalRequest({
      ...pending, timeoutSeconds: limits.timeoutSeconds, observeOnly: true
    }));
    if (result.status === 'completed_visible_terminal') pendingTasks.delete(session.sessionId);
    const structured = {
      ...result, output: trimOutput(result.output ?? '', limits.maxOutputChars),
      rawOutput: undefined, sessionId: session.sessionId, cwd: session.cwd, serverVersion: SERVER_VERSION,
      manualInputRequired: ['awaiting_user', 'auth_required'].includes(result.status)
    };
    return rpcResult(requestId, textResult([
      'status: ' + result.status, structured.output, result.error
    ].filter(Boolean).join('\n'), structured, result.status !== 'completed_visible_terminal'));
  } catch (e) {
    return rpcResult(requestId, textResult(e.message, { status: 'terminal_error' }, true));
  }
}

// ── Message dispatch ──────────────────────────────────────────────────────────

async function callTool(requestId, params) {
  const args = params?.arguments ?? {};
  const name = params?.name;

  if (name === 'agy_status') return handleAgyStatus(requestId, args);
  if (name === 'agy_open') return handleSessionControl(requestId, args, 'open');
  if (name === 'agy_read') return handleSessionControl(requestId, args, 'read');
  if (name === 'agy_wait') return handleAgyWait(requestId, args);
  if (name === 'agy_run') return handleAgyRun(requestId, args);
  if (name === 'terminal_run') return handleTerminalRun(requestId, args);

  return rpcError(requestId, -32602, `Unknown tool: ${name ?? '(missing)'}`);
}

async function handleMessage(message) {
  if (!message || typeof message !== 'object') return;
  const { id, method, params } = message;

  if (method === 'notifications/initialized') return;

  if (method === 'initialize') {
    send(rpcResult(id, {
      protocolVersion: params?.protocolVersion || PROTOCOL_VERSION,
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
      instructions: [
        `agy-terminal v${SERVER_VERSION}.`,
        'Call agy_open to open or reuse a visible AGY terminal in the authorized project.',
        'Call agy_read to see the same terminal the user sees without pressing any keys.',
        'Leave manual confirmations and login to the user; use agy_wait after they handle a pending task prompt.',
        'Confirmations are manual by default; autoApprove:true in worker mode permits only scoped file-edit confirmations.',
        'Shell commands, OAuth, login, delete, and out-of-scope paths are never auto-approved.',
        'target="auto" is not supported — omit target or the parameter entirely.',
        'Call agy_status to check session readiness before agy_run.',
        'terminal_run is for explicit user-authorized PowerShell commands only.'
      ].join(' ')
    }));
    return;
  }

  if (method === 'ping') { send(rpcResult(id, {})); return; }

  if (method === 'tools/list') {
    send(rpcResult(id, { tools: [agyOpenTool, agyReadTool, agyWaitTool, agyStatusTool, agyRunTool, terminalRunTool] }));
    return;
  }

  if (method === 'tools/call') {
    try { send(await callTool(id, params)); }
    catch (e) { send(rpcResult(id, textResult(e.message, { status: 'tool_error' }, true))); }
    return;
  }

  if (method === 'shutdown') {
    send(rpcResult(id, null));
    process.exitCode = 0;
    return;
  }

  if (id !== undefined) send(rpcError(id, -32601, `Method not found: ${method}`));
}

// ── Entry point ───────────────────────────────────────────────────────────────

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', (line) => {
  if (!line.trim()) return;
  try {
    const message = JSON.parse(line);
    if (Array.isArray(message)) {
      for (const item of message) void handleMessage(item);
    } else {
      void handleMessage(message);
    }
  } catch (e) {
    send(rpcError(null, -32700, `Invalid JSON: ${e.message}`));
  }
});
