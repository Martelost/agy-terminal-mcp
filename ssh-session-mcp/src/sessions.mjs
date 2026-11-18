import { spawn } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { EventEmitter } from 'node:events';

const BUFFER_LIMIT = 1024 * 1024;
const HISTORY_LIMIT = 64;
const quotePosix = (value) => `'${value.replaceAll("'", "'\\''")}'`;

export function shellInvocation(shell) {
  return shell === 'powershell'
    ? 'powershell.exe -NoLogo -NoProfile -NonInteractive -Command -'
    : 'sh -s';
}

export function frameCommand(shell, command, marker) {
  if (shell === 'posix') {
    // Parse the full compound command before eval runs: a child reading stdin
    // must not consume the completion marker as its input.
    return `eval ${quotePosix(command)}; __mcp_rc=$?; printf '\\n${marker}%s\\n' "$__mcp_rc"\n`;
  }
  const encoded = Buffer.from(command, 'utf8').toString('base64');
  return `$global:LASTEXITCODE=0; $__mcp_errorBefore=$Error[0]; try { . ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${encoded}')))) 2>&1 | Out-String -Stream | ForEach-Object { [Console]::Out.WriteLine($_) }; $__mcp_ok=$?; $__mcp_rc=0; if ($global:LASTEXITCODE -ne 0) { $__mcp_rc=$global:LASTEXITCODE } elseif (!$__mcp_ok -or $Error[0] -ne $__mcp_errorBefore) { $__mcp_rc=1 } } catch { [Console]::Out.WriteLine($_.ToString()); $__mcp_rc=1 }; [Console]::Out.Write([string][char]10); [Console]::Out.Write('${marker}'+$__mcp_rc); [Console]::Out.Write([string][char]10)\n`;
}

export class Operation extends EventEmitter {
  constructor(session) {
    super();
    this.id = randomUUID();
    this.session = session;
    this.marker = `__SSH_MCP_${randomBytes(24).toString('hex')}__`;
    this.status = 'running';
    this.exitCode = null;
    this.output = '';
    this.startCursor = 0;
    this.endCursor = 0;
    this.startedAt = new Date().toISOString();
  }
  append(text) {
    if (!text) return;
    this.output += text;
    this.endCursor += text.length;
    if (this.output.length > BUFFER_LIMIT) {
      const dropped = this.output.length - BUFFER_LIMIT;
      this.output = this.output.slice(dropped);
      this.startCursor += dropped;
    }
    this.emit('change');
  }
  finish(status, exitCode = null, error = null) {
    if (this.status !== 'running') return;
    this.status = status;
    this.exitCode = exitCode;
    this.error = error;
    this.finishedAt = new Date().toISOString();
    this.emit('change');
  }
  async wait(ms, { cursor, completion = false } = {}) {
    if (!ms || this.status !== 'running' || (!completion && this.endCursor > cursor)) return;
    await new Promise((resolve) => {
      const done = () => {
        if (completion && this.status === 'running') return;
        clearTimeout(timer); this.off('change', done); resolve();
      };
      const timer = setTimeout(() => { this.off('change', done); resolve(); }, ms);
      this.on('change', done);
    });
  }
  snapshot(cursor = 0, maxChars = 16000) {
    const start = Math.max(cursor, this.startCursor);
    const next = Math.min(this.endCursor, start + maxChars);
    return { host: this.session.profile.name, session_id: this.session.id,
      operation_id: this.id, status: this.status, exit_code: this.exitCode,
      output: this.output.slice(start - this.startCursor, next - this.startCursor).replaceAll('\r\n', '\n'),
      next_cursor: next, truncated: cursor < this.startCursor, has_more: next < this.endCursor,
      started_at: this.startedAt, finished_at: this.finishedAt ?? null, error: this.error ?? null };
  }
}

class ShellSession {
  constructor(profile, spawnProcess) {
    this.profile = profile;
    this.id = randomUUID();
    this.state = 'connecting';
    this.startedAt = new Date().toISOString();
    this.pending = '';
    this.diagnostics = '';
    this.active = null;
    const args = ['-T', '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes',
      '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3',
      '-o', 'LogLevel=ERROR', '-i', profile.identityFile, '-p', String(profile.port),
      `${profile.username}@${profile.hostname}`, shellInvocation(profile.shell)];
    this.child = spawnProcess(process.env.SSH_SESSION_EXECUTABLE || 'ssh', args,
      { stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    this.child.stdout.setEncoding('utf8');
    this.child.stderr.setEncoding('utf8');
    this.child.stdout.on('data', (chunk) => this.consume(chunk));
    this.child.stderr.on('data', (chunk) => {
      this.diagnostics = (this.diagnostics + chunk).slice(-16000);
      this.active?.append(chunk);
    });
    this.child.stdin.on('error', (error) => this.disconnect(`SSH input closed: ${error.message}`));
    this.child.on('error', (error) => this.disconnect(`Cannot start SSH: ${error.message}`));
    this.child.on('close', (code, signal) => this.disconnect(
      `SSH disconnected (${signal ?? code ?? 'unknown'}). ${this.diagnostics.trim()}`));
  }
  async connect() {
    const initialize = this.profile.shell === 'posix' ? 'exec 2>&1; :' :
      '[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $OutputEncoding=[Console]::OutputEncoding; $ProgressPreference="SilentlyContinue"';
    const op = this.start(initialize);
    await op.wait(15000, { completion: true });
    if (op.status !== 'completed' || op.exitCode !== 0) {
      const message = op.error || this.diagnostics.trim() || 'SSH shell handshake failed or timed out.';
      this.close(); throw new Error(message);
    }
    this.state = 'connected';
    return this;
  }
  start(command) {
    if (!['connected', 'connecting'].includes(this.state)) throw new Error('SSH session is disconnected.');
    if (this.active) throw new Error(`Host ${this.profile.name} is busy. Read operation ${this.active.id} before submitting another command.`);
    const op = new Operation(this);
    this.active = op;
    this.lastUsedAt = new Date().toISOString();
    this.child.stdin.write(frameCommand(this.profile.shell, command, op.marker), 'utf8');
    return op;
  }
  consume(chunk) {
    this.pending += chunk;
    const op = this.active;
    if (!op) { this.pending = ''; return; }
    const tag = `\n${op.marker}`;
    const index = this.pending.indexOf(tag);
    if (index >= 0) {
      const suffix = this.pending.slice(index + tag.length);
      const match = /^(-?\d+)\r?\n/.exec(suffix);
      if (!match) {
        op.append(this.pending.slice(0, index));
        this.pending = this.pending.slice(index); return;
      }
      op.append(this.pending.slice(0, index));
      this.pending = '';
      this.active = null;
      op.finish('completed', Number(match[1]));
      return;
    }
    let keep = Math.min(tag.length - 1, this.pending.length);
    while (keep && !tag.startsWith(this.pending.slice(-keep))) keep--;
    op.append(keep ? this.pending.slice(0, -keep) : this.pending);
    this.pending = keep ? this.pending.slice(-keep) : '';
  }
  disconnect(message) {
    if (this.state === 'disconnected') return;
    this.state = 'disconnected';
    if (this.active) {
      this.active.append(this.pending); this.pending = '';
      this.active.finish('disconnected', null, message); this.active = null;
    }
    this.lastError = message;
  }
  close() {
    this.disconnect('SSH session closed. Commands are not automatically replayed.');
    this.child.kill();
  }
  info() {
    return { host: this.profile.name, session_id: this.id, state: this.state,
      pid: this.child.pid ?? null, started_at: this.startedAt,
      last_used_at: this.lastUsedAt ?? null, active_operation: this.active?.id ?? null,
      error: this.lastError ?? null };
  }
}

export class SessionManager {
  constructor(profiles, { spawnProcess = spawn } = {}) {
    this.profiles = profiles;
    this.spawnProcess = spawnProcess;
    this.sessions = new Map();
    this.opening = new Map();
    this.operations = new Map();
  }
  list() {
    return [...this.profiles.values()].map((profile) => ({ host: profile.name,
      hostname: profile.hostname, username: profile.username, shell: profile.shell,
      session: this.sessions.get(profile.name)?.info() ?? null }));
  }
  async open(host) {
    const profile = this.profiles.get(host);
    if (!profile) throw new Error(`Unknown host ${host}. Use ssh_hosts to list configured names.`);
    if (this.opening.has(host)) return this.opening.get(host);
    const existing = this.sessions.get(host);
    if (existing?.state === 'connected') return existing;
    const session = new ShellSession(profile, this.spawnProcess);
    this.sessions.set(host, session);
    const opening = session.connect();
    this.opening.set(host, opening);
    try { return await opening; } finally { this.opening.delete(host); }
  }
  async run(host, command, waitMs = 1000, maxChars = 16000) {
    if (typeof command !== 'string' || !command.trim() || command.includes('\0') || command.length > 131072) {
      throw new Error('command must be nonempty text without NUL, at most 131072 characters.');
    }
    const session = await this.open(host);
    const op = session.start(command);
    this.operations.set(op.id, op);
    for (const [id, previous] of this.operations) {
      if (this.operations.size <= HISTORY_LIMIT) break;
      if (previous.status !== 'running') this.operations.delete(id);
    }
    await op.wait(waitMs, { completion: true });
    return op.snapshot(0, maxChars);
  }
  operation(host, id) {
    const op = this.operations.get(id);
    if (!op || op.session.profile.name !== host) throw new Error('Unknown or expired operation for this host.');
    return op;
  }
  async read(host, id, cursor = 0, waitMs = 1000, maxChars = 16000) {
    const op = this.operation(host, id);
    if (cursor > op.endCursor) throw new Error('cursor is beyond the end of this operation.');
    await op.wait(waitMs, { cursor });
    return op.snapshot(cursor, maxChars);
  }
  input(host, id, data, newline = true) {
    const op = this.operation(host, id);
    if (op.status !== 'running' || op.session.active !== op) throw new Error('Only a running operation can receive input.');
    op.session.child.stdin.write(data + (newline ? '\n' : ''), 'utf8');
    return { host, operation_id: id, status: 'input_sent' };
  }
  close(host) {
    if (!this.profiles.has(host)) throw new Error(`Unknown host ${host}.`);
    this.sessions.get(host)?.close();
    return { host, status: 'closed' };
  }
  closeAll() { for (const session of this.sessions.values()) session.close(); }
}
